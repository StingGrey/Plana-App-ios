// 开机路径上的两条「不能骗人」的规矩,都是**会花钱**的那种错。
//
// ① 客户端断网 / 超时 **不等于没开成**:服务端很可能已经把机器建起来了。
//    一见异常就标成「开机失败 · 没有扣费」的话,用户会以为什么都没发生地走开,
//    而那台机器在后台一路烧到 4 小时硬上限。异常路径必须回去问服务端。
// ② 2026-08-19 起 /api/rental/start **不再阻塞到就绪**:服务端把建机丢进
//    后台(_fire_and_forget)然后同步取合并视图就返回,那几个后台任务一行都
//    还没跑 —— 所以返回体里恒是 state:"none"、machines:[]。照单全收的话界面
//    立刻退回「未启动」、轮询也跟着停掉,而机器在后台照开照计费;更糟的是这时
//    busy 和 active 都是 false,再点一次会**真的加开一台**(start 的语义已经
//    从「返回那台已有的」变成「加开」,上限 4 台)。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/generate/gpu_rental.dart';

/// 可编排的假 client:start 默认抛异常([startJson] 给了就改成正常返回),
/// status 按预设返回(给多份就按调用次序逐个吐,用来演「先 none 后 creating」)。
class _FakeClient extends BackendClient {
  _FakeClient({required this.statusJson, this.startJson}) : super('http://test');

  /// 每次 rentalStatus 依次取一份,取完之后一直用最后一份。
  final List<Map<String, dynamic>> statusJson;
  final Map<String, dynamic>? startJson;
  int statusCalls = 0;
  String? startedTier;
  int startedCount = 0;
  String? stoppedIid;

  @override
  Future<Map<String, dynamic>> rentalStatus(String sessionId) async {
    final i = statusCalls++;
    return statusJson[i < statusJson.length ? i : statusJson.length - 1];
  }

  @override
  Future<Map<String, dynamic>> rentalStart(
    String sessionId, {
    int? idleTimeout,
    String tier = '',
    int count = 1,
  }) async {
    startedTier = tier;
    startedCount = count;
    final j = startJson;
    if (j == null) throw BackendException('连接后端超时,请检查地址与网络');
    return j;
  }

  @override
  Future<Map<String, dynamic>> rentalStop(
    String sessionId, {
    String instanceId = '',
  }) async {
    stoppedIid = instanceId;
    return {'ok': true, 'price': 0.3, 'minutes': 6.0};
  }
}

/// 已登录的会话(租卡端点全要它)。
class _FakeSession extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async => const BotSession(sessionId: 's1');
}

ProviderContainer _container(_FakeClient client) {
  final c = ProviderContainer(
    overrides: [
      backendClientProvider.overrideWithValue(client),
      botSessionProvider.overrideWith(_FakeSession.new),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Map<String, dynamic> _running() => {
  'ok': true,
  'active': true,
  'state': 'ready',
  'instance_id': 'uhost-abc',
  'idle_timeout': 600,
  'elapsed_s': 120,
  'price': 0.1,
  'rate_per_hour': 3.0,
};

Map<String, dynamic> _none() => {
  'ok': true,
  'active': false,
  'state': 'none',
  'rate_per_hour': 3.0,
};

/// 服务端 `_agg()` 在还没有 Rental 时的样子。**start 成功返回的就是这一份** ——
/// 后台建机任务此刻一行都还没跑。
Map<String, dynamic> _startAccepted() => {
  'ok': true,
  'message': '正在启动',
  'active': false,
  'state': 'none',
  'count': 0,
  'machines': <dynamic>[],
  'rate_per_hour': 2.7,
};

/// 建机任务跑起来之后的 status:每台的机型/档位只在 machines[i] 里。
Map<String, dynamic> _booting() => {
  'ok': true,
  'active': true,
  'state': 'creating',
  'count': 1,
  'max_count': 4,
  'machines': [
    {
      'instance_id': 'uhost-abc',
      'state': 'creating',
      'tier': 'wlcb-4090-spot',
      'tier_label': '抢占 4090',
      'spot': true,
      'spec': {
        'gpu': 'RTX 4090',
        'gpu_count': 1,
        'cpu': 16,
        'memory_gb': 64,
        'disk_gb': 100,
        'vram_gb': 24,
      },
      'rate_per_hour': 1.4,
    },
  ],
  'elapsed_s': 0,
  'price': 0.0,
  'rate_per_hour': 1.4,
};

/// 两台在跑:一台已就绪、一台还在开。合并视图里 elapsed 取最早那台的、
/// price 与 rate 是**和**,而机型/档位/逐台读数只在 machines[i] 里。
Map<String, dynamic> _twoMachines() => {
  'ok': true,
  'active': true,
  'state': 'creating', // 有一台还在开 → 合并状态就是 creating
  'count': 2,
  'max_count': 4,
  'machines': [
    {
      'instance_id': 'a',
      'state': 'ready',
      'tier': 'sh2-5090',
      'tier_label': '独享 5090',
      'rate_per_hour': 2.7,
      'elapsed_s': 600,
      'price': 0.45,
    },
    {
      'instance_id': 'b',
      'state': 'creating',
      'tier': 'wlcb-4090-spot',
      'tier_label': '抢占 4090',
      'spot': true,
      'rate_per_hour': 1.4,
      'elapsed_s': 0,
      'price': 0.0,
    },
  ],
  'elapsed_s': 600,
  'price': 0.45,
  'rate_per_hour': 4.1, // 两台之和,含还在开机那台
  'jobs_done': 3,
};

void main() {
  // GpuRentalNotifier.build 里挂了 AppLifecycleListener(回前台补一次状态),
  // 那个要 widgets binding
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start 返回的空视图不能把界面打回「未启动」(会重复开机)', () async {
    // 第 1 发是会话到货时的 refresh(还没开机),第 2 发是 start 之后补问的
    final client = _FakeClient(
      statusJson: [_none(), _booting()],
      startJson: _startAccepted(),
    );
    final c = _container(client);
    await c.read(botSessionProvider.future);
    await Future<void>.delayed(Duration.zero);

    await c.read(gpuRentalProvider.notifier).start(600, tier: 'wlcb-4090-spot');
    final s = c.read(gpuRentalProvider);

    expect(client.startedTier, 'wlcb-4090-spot', reason: '选的档位要发出去');
    expect(
      s.status,
      RentalStatus.creating,
      reason: 'start 返回体里的 state 是空视图,不能拿它当真',
    );
    expect(s.active, isTrue, reason: '不 active 的话 _rearm 会把轮询停掉,状态就再也不更新了');
    expect(s.busy, isFalse);
    // 机型/档位只在 machines[i] 里 —— 合并视图 _agg 根本没有 spec 这个键
    expect(s.tierLabel, '抢占 4090');
    expect(s.spot, isTrue);
    expect(s.spec.gpu, 'RTX 4090');
    expect(s.spec.vramGb, 24);
    expect(s.count, 1);
  });

  test('启动中的机器从服务端名单里消失 = 开机失败,不是悄悄回到未启动', () async {
    final client = _FakeClient(
      statusJson: [_none(), _booting(), _none()],
      startJson: _startAccepted(),
    );
    final c = _container(client);
    await c.read(botSessionProvider.future);
    await Future<void>.delayed(Duration.zero);

    await c.read(gpuRentalProvider.notifier).start(600);
    expect(c.read(gpuRentalProvider).status, RentalStatus.creating);

    // 第 3 发:服务端 _boot_one 失败后把这台从名单里摘掉了(销毁 + 一分不收)
    await c.read(gpuRentalProvider.notifier).refresh();
    final s = c.read(gpuRentalProvider);
    expect(s.status, RentalStatus.failed);
    expect(s.note, isNotEmpty, reason: '失败原因要说出来,不能无声无息退回未启动');
  });

  test('档位清单跟着 status 下发,存的档位没了就退回默认档', () {
    const s = RentalState(
      tiers: [
        RentalTier(key: 'a', label: '独享 5090', ratePerHour: 2.7, isDefault: true),
        RentalTier(key: 'b', label: '抢占 4090', ratePerHour: 1.4, spot: true),
      ],
    );
    expect(s.resolveTier('b')?.key, 'b');
    expect(
      s.resolveTier('gone')?.key,
      'a',
      reason: '服务端对不认识的键就是静默回落默认档,界面得跟着落,不能显示一套开出另一套',
    );
    expect(s.resolveTier('')?.key, 'a');
  });

  test('一次开多台:count 发出去,逐台明细读得回来', () async {
    final client = _FakeClient(
      statusJson: [_none(), _twoMachines()],
      startJson: _startAccepted(),
    );
    final c = _container(client);
    await c.read(botSessionProvider.future);
    await Future<void>.delayed(Duration.zero);

    await c.read(gpuRentalProvider.notifier).start(600, count: 3);
    expect(client.startedCount, 3, reason: '选了几台就得发几台');

    final s = c.read(gpuRentalProvider);
    expect(s.count, 2);
    expect(s.machines, hasLength(2));
    expect(s.machines[0].label, '独享 5090');
    expect(s.machines[1].label, '抢占 4090');
    expect(s.machines[1].spot, isTrue);
    expect(s.room, 2, reason: '上限 4 台,已有 2 台');
  });

  test('多台的读数:有一台在跑就得走字,费用以 price 为锚点而不是时长×费率',
      () async {
    final client = _FakeClient(
      statusJson: [_none(), _twoMachines()],
      startJson: _startAccepted(),
    );
    final c = _container(client);
    await c.read(botSessionProvider.future);
    await Future<void>.delayed(Duration.zero);
    await c.read(gpuRentalProvider.notifier).start(600, count: 2);
    final s = c.read(gpuRentalProvider);

    // 合并状态是 creating(有一台还在开),但另一台早就在收钱了
    expect(s.status, RentalStatus.creating);
    expect(s.billing, isTrue, reason: '有一台 ready 就是在计费,读数不能停着');
    expect(
      s.billingRate,
      2.7,
      reason: '插值只能按**在跑那几台**的费率;把还在开机那台的 1.4 也算进去,'
          '下一轮轮询就会把金额往回拉,看着像跳票',
    );

    // 拿 60 秒之后的读数:price 0.45 + 60s × 2.7/时 = 0.495
    final later = s.fetchedAtMs + 60000;
    expect(s.priceAt(later), closeTo(0.495, 1e-6));
    // 反例:elapsedAt × rate_per_hour = 660/3600 × 4.1 = 0.7517,差了六成
    expect(s.elapsedAt(later), 660);
  });

  test('只关一台:instance_id 要发出去,别把别人的机器一起关了', () async {
    final client = _FakeClient(
      statusJson: [_none(), _twoMachines()],
      startJson: _startAccepted(),
    );
    final c = _container(client);
    await c.read(botSessionProvider.future);
    await Future<void>.delayed(Duration.zero);
    await c.read(gpuRentalProvider.notifier).start(600, count: 2);

    await c.read(gpuRentalProvider.notifier).stop(instanceId: 'b');
    expect(client.stoppedIid, 'b');

    // 全停才是空 id
    await c.read(gpuRentalProvider.notifier).stop();
    expect(client.stoppedIid, isEmpty);
  });

  test('start 抛异常但服务端其实开成了 → 不能报「开机失败」', () async {
    final client = _FakeClient(statusJson: [_running()]);
    final c = _container(client);
    // 会话到货那一发 refresh 先跑掉
    await c.read(botSessionProvider.future);
    await Future<void>.delayed(Duration.zero);

    await c.read(gpuRentalProvider.notifier).start(600);
    final s = c.read(gpuRentalProvider);

    expect(s.status, RentalStatus.ready, reason: '以服务端的 status 为准');
    expect(s.active, isTrue, reason: '机器在跑,关机入口必须还在');
    expect(s.busy, isFalse);
    // 补问那一发成功了,就没什么可报的:面板直接显示「运行中」。
    // 留着那句「同步失败」反而误导 —— 失败的是上一次,这一次是准的。
    expect(s.error, isEmpty);
  });

  test('start 抛异常且服务端确实没有实例 → 才是开机失败', () async {
    final client = _FakeClient(statusJson: [_none()]);
    final c = _container(client);
    await c.read(botSessionProvider.future);
    await Future<void>.delayed(Duration.zero);

    await c.read(gpuRentalProvider.notifier).start(600);
    final s = c.read(gpuRentalProvider);

    expect(s.status, RentalStatus.failed);
    expect(s.active, isFalse);
    expect(s.note, isNotEmpty, reason: '失败原因要说出来');
  });

  test('没有会话时整条路不可用,也不去打接口', () async {
    final client = _FakeClient(statusJson: [_none()]);
    final c = ProviderContainer(
      overrides: [backendClientProvider.overrideWithValue(client)],
    );
    addTearDown(c.dispose);
    // 默认 BotSessionNotifier 在测试环境读不到 secure storage → null 会话
    await Future<void>.delayed(Duration.zero);
    await c.read(gpuRentalProvider.notifier).start(600);
    expect(c.read(gpuRentalProvider).status, RentalStatus.none);
    expect(client.statusCalls, 0);
  });
}
