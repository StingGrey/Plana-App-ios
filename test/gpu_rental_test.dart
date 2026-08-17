// 租卡的读数口径必须与服务端 agent_router/img_rental.py 一致。这几条不是 UI
// 细节,是钱:算错一处,界面报的数字和账单对不上,用户第一时间就不信任这功能。
//
//   ① 计费从**建实例**起算(不是从就绪),开机与首张图的加载都算在租用时长里;
//   ② 但没就绪过 = 一分不收 —— 服务端 billed_seconds 在 ready_at 为 0 时返回 0,
//      所以「启动中」界面上的读数恒为 0,就绪那一刻才跳到含启动时长的值;
//   ③ 已用时长/费用**以服务端为准**,本地只在两次轮询之间按秒插值。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/gpu_rental.dart';

/// 服务端 `Rental.public()` 的形状(active 时)。
Map<String, dynamic> _public({
  String state = 'ready',
  int elapsed = 600,
  double price = 0.5,
}) => {
  'ok': true,
  'active': state != 'none',
  'state': state,
  'instance_id': 'uhost-abc',
  'idle_timeout': 600,
  'elapsed_s': elapsed,
  'price': price,
  'rate_per_hour': 3.0,
  'jobs_done': 4,
  'jobs_failed': 1,
  'note': '',
  'idle_choices': [180, 600, 1800, 0],
  'max_uptime_s': 4 * 3600,
};

void main() {
  group('合入服务端状态', () {
    test('public() 各字段落位', () {
      final s = const RentalState().merge(_public(), 1000);
      expect(s.status, RentalStatus.ready);
      expect(s.instanceId, 'uhost-abc');
      expect(s.idleSeconds, 600);
      expect(s.elapsedS, 600);
      expect(s.price, 0.5);
      expect(s.ratePerHour, 3.0);
      expect(s.jobsDone, 4);
      expect(s.jobsFailed, 1);
      expect(s.idleChoices, [180, 600, 1800, 0]);
      expect(s.maxUptimeS, 4 * 3600);
      expect(s.active, isTrue);
      expect(s.authed, isTrue);
    });

    test('未启动那份带可选项,不带实例读数', () {
      final s = const RentalState().merge(const {
        'ok': true,
        'active': false,
        'state': 'none',
        'rate_per_hour': 3.0,
        'idle_choices': [180, 600, 1800, 0],
        'idle_default': 600,
        'max_uptime_s': 4 * 3600,
        'boot_hint_s': 40,
        'first_image_hint_s': 25,
      }, 1000);
      expect(s.status, RentalStatus.none);
      expect(s.active, isFalse);
      expect(s.idleDefault, 600);
      expect(s.bootHintS, 40);
      expect(s.firstImageHintS, 25);
      expect(s.elapsedS, 0);
    });

    test('认不出的 state 一律当未启动,不抛', () {
      expect(
        const RentalState().merge(const {'state': '什么态'}, 0).status,
        RentalStatus.none,
      );
    });

    test('缺字段时保留原有可选项(status 那份不带 idle_default)', () {
      final base = const RentalState().merge(_public(state: 'none'), 0);
      // _public 没有 idle_default / boot_hint_s,不能把已知值冲成 0
      expect(base.idleDefault, kIdleDefaultFallback);
      expect(base.bootHintS, kBootHintFallback);
    });
  });

  group('读数插值', () {
    test('运行中按秒往前走', () {
      final s = const RentalState().merge(_public(elapsed: 600), 10000);
      expect(s.elapsedAt(10000), 600); // 刚取到
      expect(s.elapsedAt(40000), 630); // 30 秒后
      expect(s.priceAt(40000), closeTo(630 / 3600 * 3.0, 0.001));
    });

    // 服务端 billed_seconds 在就绪前恒为 0(没交付不收),别在本地把它插成正数 ——
    // 那会让「启动中」显示出一个根本不存在的费用
    test('启动中不插值,恒为服务端那个 0', () {
      final s = const RentalState().merge(
        _public(state: 'creating', elapsed: 0, price: 0),
        10000,
      );
      expect(s.elapsedAt(999999), 0);
      expect(s.priceAt(999999), 0);
    });

    test('关机中冻在最后一次读数上(不再往前跑)', () {
      final s = const RentalState().merge(
        _public(state: 'ending', elapsed: 600, price: 0.5),
        10000,
      );
      expect(s.elapsedAt(999999), 600);
      expect(s.priceAt(999999), 0.5);
    });

    test('没有锚点时不乱算', () {
      const s = RentalState(status: RentalStatus.ready, elapsedS: 60);
      expect(s.elapsedAt(999999), 60); // fetchedAtMs=0 → 不加漂移
    });

    test('时钟回拨不出负数', () {
      final s = const RentalState().merge(_public(elapsed: 600), 100000);
      expect(s.elapsedAt(0), 600);
    });
  });

  group('实例状态', () {
    test('active 覆盖三种「占着机器」的状态', () {
      for (final st in ['creating', 'ready', 'ending']) {
        final s = const RentalState().merge({'state': st}, 0);
        expect(s.active, isTrue, reason: st);
      }
      // 未启动与失败都不占机器 —— 顶栏胶囊据此决定出不出
      expect(const RentalState().merge(const {'state': 'none'}, 0).active, isFalse);
      expect(
        const RentalState().merge(const {'state': 'failed'}, 0).active,
        isFalse,
      );
    });
  });

  group('空闲自动关机', () {
    test('0 = 不自动关,其余按分钟报', () {
      expect(idleLabel(0), '不自动关');
      expect(idleLabel(180), '3 分钟');
      expect(idleLabel(600), '10 分钟');
    });

    // 兜底值只在拿不到 status 时用,但也得和服务端 config.py 对得上,
    // 否则首屏那一眼会显示一套和真实规则不同的数字
    test('兜底默认对齐服务端 config', () {
      expect(kIdleChoicesFallback, [180, 600, 1800, 0]);
      expect(kIdleDefaultFallback, 600);
      expect(kMaxUptimeFallback, 4 * 3600);
      // 两段等待分开报:合成一个数会让文案骗人(服务端注释里记着这个教训)
      expect(kBootHintFallback, 40);
      expect(kFirstImageHintFallback, 25);
      expect(kRateFallback, 3.0);
    });
  });

  group('偏好持久化', () {
    test('往返不丢', () {
      const p = RentalPrefs(channel: ModalChannel.rented, idleSeconds: 1800);
      final back = RentalPrefs.fromJson(p.toJson());
      expect(back.channel, ModalChannel.rented);
      expect(back.idleSeconds, 1800);
    });

    test('默认免费通道 —— 掏钱这件事绝不能是默认', () {
      expect(const RentalPrefs().channel, ModalChannel.free);
      expect(RentalPrefs.fromJson(const {}).channel, ModalChannel.free);
      expect(RentalPrefs.fromJson(const {}).idleSeconds, kIdleDefaultFallback);
    });
  });

  group('读数格式', () {
    test('不足一小时不摆小时位', () {
      expect(fmtUptime(0), '00:00');
      expect(fmtUptime(65), '01:05');
      expect(fmtUptime(3599), '59:59');
      expect(fmtUptime(3661), '1:01:01');
    });

    test('金额两位小数', () {
      expect(fmtYuan(0), '¥0.00');
      expect(fmtYuan(1.234), '¥1.23');
    });
  });
}
