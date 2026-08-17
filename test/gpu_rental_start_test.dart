// 开机那 80 多秒里,客户端这边断网 / 超时 **不等于没开成**。
//
// 服务端 /api/rental/start 是阻塞到就绪才返回的,期间机器已经建起来、已经在
// 计费。如果 app 一见异常就把状态标成「开机失败 · 没有扣费」,用户会以为什么
// 都没发生地走开,而那台机器在后台一路烧到 4 小时硬上限(¥12)。
// 所以异常路径必须回去问服务端,以它的 status 为准。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/generate/gpu_rental.dart';

/// 可编排的假 client:start 抛异常,status 按预设返回。
class _FakeClient extends BackendClient {
  _FakeClient({required this.statusJson}) : super('http://test');

  final Map<String, dynamic> statusJson;
  int statusCalls = 0;

  @override
  Future<Map<String, dynamic>> rentalStatus(String sessionId) async {
    statusCalls++;
    return statusJson;
  }

  @override
  Future<Map<String, dynamic>> rentalStart(
    String sessionId, {
    int? idleTimeout,
  }) async {
    throw BackendException('连接后端超时,请检查地址与网络');
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

void main() {
  // GpuRentalNotifier.build 里挂了 AppLifecycleListener(回前台补一次状态),
  // 那个要 widgets binding
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start 抛异常但服务端其实开成了 → 不能报「开机失败」', () async {
    final client = _FakeClient(statusJson: _running());
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
    final client = _FakeClient(statusJson: _none());
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
    final client = _FakeClient(statusJson: _none());
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
