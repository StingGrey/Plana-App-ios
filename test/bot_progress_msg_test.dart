// 一条 `task_progress` 里同时躺着三样东西:步数读数、阶段文案、准备阶段百分比。
// 采样**开始之前**(拉 LoRA、加载模型,付费档实例那几十秒到几分钟)服务端也推
// 这条消息,但那时真实 step/total 都是 0 —— 该显示的是文案和百分比,不是步数。
//
// 这里钉的就是「这条消息该怎么读」这一个判断。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/bot_stream.dart';

void main() {
  group('准备阶段(采样还没开始)', () {
    test('新服务端直接报 0/0:读数不采信,只取文案和百分比', () {
      final r = readProgressMsg(const {
        'step': 0,
        'total_steps': 0,
        'stage_text': 'LoRA 42%',
        'phase': 'lora',
        'phase_pct': 42,
      });
      expect(r.stage, 'LoRA 42%');
      expect(r.pct, 42);
      expect(r.useSteps, isFalse, reason: '采信了进度条分母就没了');
    });

    // 老服务端把 0 按 max(step,1)/max(total,1) 夹成 1/1 下发,
    // 照单全收的话进度条会在装模型时就顶到满格然后停住
    test('老服务端的 1/1:同样不采信', () {
      final r = readProgressMsg(const {
        'step': 1,
        'total_steps': 1,
        'stage_text': '准备 LoRA',
      });
      expect(r.stage, '准备 LoRA');
      expect(r.useSteps, isFalse, reason: '采信了进度条会直接满格');
    });

    // 换阶段服务端就不再下发 phase_pct。取不到必须回到 -1,让调用方把上一段
    // 留下的百分比清掉 —— 否则「加载模型」会顶着 100% 不动,比没有条更像卡死
    test('加载模型那段没有百分比 → -1', () {
      final r = readProgressMsg(const {
        'step': 0,
        'total_steps': 0,
        'stage_text': '加载模型',
        'phase': 'loading',
      });
      expect(r.pct, -1);
      expect(r.useSteps, isFalse);
    });

    // boto3 内部重试会把同一段重下并再回调一次,服务端那边已经夹过一次,
    // 这里再兜一道:宁可停在 100 也不能报 137%
    test('百分比越界一律夹回 0..100', () {
      expect(readProgressMsg(const {'phase_pct': 137}).pct, 100);
      expect(readProgressMsg(const {'phase_pct': -5}).pct, -1);
    });
  });

  group('采样期', () {
    test('读数照常采信,文案一起带出来', () {
      final r = readProgressMsg(const {
        'step': 3,
        'total_steps': 36,
        'stage_text': '生成中 3/36',
        'phase': 'sampling',
      });
      expect(r.useSteps, isTrue);
      expect(r.step, 3);
      expect(r.total, 36);
      expect(r.stage, '生成中 3/36');
    });

    // anima 的重绘放大是 hires 二段:第二段的 step 从 1 重新开始。
    // 判据里那个「total 也得 <= 1」就是为了把它择出去 —— 当成「还没开始」
    // 的话第二段整段都被吃掉,进度条卡在满格不动直到出图
    test('重绘二段从 step=1 重新开始:是真读数', () {
      final r = readProgressMsg(const {
        'step': 1,
        'total_steps': 28,
        'stage_text': '生成中 1/28',
      });
      expect(r.useSteps, isTrue);
      expect(r.step, 1);
    });

    // 采样跑满之后还有一段(VAE 解码 / 存盘 / 跨境取图),它带着满读数发过来。
    // 文案得跟读数走同一路 —— 分两次给的话后到的读数会把文案抹掉,
    // 而那正是用户盯着满进度条等图的几秒
    test('收尾的「取图中」带着满读数一起来', () {
      final r = readProgressMsg(const {
        'step': 36,
        'total_steps': 36,
        'stage_text': '取图中',
        'phase': 'fetching',
      });
      expect(r.useSteps, isTrue);
      expect(r.stage, '取图中');
    });
  });

  group('免费档 / NAI 直连(不带 stage_text)', () {
    // 判据里那个「有文案」就是为了把它择出去 ——
    // NAI 真的只跑一步时 1/1 是真读数,不能当成「还没开始」
    test('没有阶段文案的 1/1 是真读数(NAI 单步)', () {
      final r = readProgressMsg(const {'step': 1, 'total_steps': 1});
      expect(r.stage, isEmpty);
      expect(r.useSteps, isTrue);
    });

    test('常规进度:一如既往', () {
      final r = readProgressMsg(const {'step': 12, 'total_steps': 28});
      expect(r.stage, isEmpty);
      expect(r.pct, -1);
      expect(r.useSteps, isTrue);
      expect(r.step, 12);
      expect(r.total, 28);
    });

    test('空文案当没有(不能因为一个空串就把读数丢了)', () {
      final r = readProgressMsg(const {
        'step': 1,
        'total_steps': 1,
        'stage_text': '   ',
      });
      expect(r.stage, isEmpty);
      expect(r.useSteps, isTrue);
    });
  });

  test('缺字段一律按 0 / -1,不抛', () {
    final r = readProgressMsg(const {});
    expect(r.step, 0);
    expect(r.total, 0);
    expect(r.pct, -1);
    expect(r.stage, isEmpty);
    expect(r.useSteps, isTrue);
  });
}
