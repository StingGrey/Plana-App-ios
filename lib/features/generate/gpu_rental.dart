import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/store/app_stores.dart';
import '../../core/store/prefs_store.dart';

/// Anima / Krea 2 的算力来源:免费共享队列,或用户自己租的一台独享 GPU。
///
/// 对接服务端 `agent_router/img_rental.py` 的 `/api/rental/*`。
/// 下面几条是**服务端的规则**,app 侧只负责如实呈现,不能自行发挥:
///
///  - **一人一实例**,而且这一台同时服务 Anima 与 Krea 2 —— 所以通道是这两家
///    模型共用的一份设置,不是每个型号各选一份;
///  - **计费从「建实例」起算**,开机与首张图的加载时间都算在租用时长里
///    (租的是机器的使用权,不是从打着火才开始计时)。**但没起来过就一分不收**;
///  - 中途失联只计到最后一次探通(服务端 `bill_to`),发现前的空转不收;
///  - 停止是 purge + 销毁,不是停机 —— 停机实例的云盘照收钱;
///  - 除了用户设的空闲超时,还有硬上限与平台定时关机两层兜底。
///
/// 读数(已用时长 / 费用)**以服务端为准**:本地只在两次轮询之间按秒插值,
/// 保证数字会走,但每轮都会被服务端的真值拉回去。

/// 出图请求有没有被路由到租来的那台机器上。
///
/// 服务端 `modal_anima_provider._try_rental()` 已接:出图前查这人有没有
/// **state == ready** 的租用,有就投他自己那台,没有(或还在启动中、或租卡
/// 模块不可用)就回落 Modal 免费档。**分流是服务端自动做的**,app 不送字段 ——
/// `bot_user_id` 由会话推出来,没有「这一单走哪条」的参数位。
///
/// 由此带来两条界面必须说清的事,见 rental_panel:
///  ① 启动中(state=creating)出的图**仍走免费队列** —— 只有 ready 才分流;
///  ② 实例一旦在跑,出图就走它,与 app 里那个「免费/独享」开关无关 ——
///    那个开关只是「要不要租」的意图,不是每一单的路由。
const bool kRentalRoutingReady = true;

/// 机型。**服务端下单和界面展示共用同一份**(`compshare_api.SPEC`,随 status
/// 下发 `spec`)—— 前端别自己写死:改配置得记着改三处,迟早对不上
/// (服务端那份注释里点名了这个教训)。下面两个只是 status 还没到货时的占位。
///
/// 仍然只有一种机型:`create_instance` 里 `GpuType` 写死 "5090",没有参数位,
/// 所以这是展示项不是选择项。
const kRentalMachineName = 'RTX 5090';
const kRentalMachineSpec = '14 核 · 64 GB · 100 GB SSD';

/// status 下发的机型(`spec`)。字段缺失就退到上面那两个占位。
class RentalSpec {
  const RentalSpec({
    this.gpu = kRentalMachineName,
    this.gpuCount = 1,
    this.cpu = 14,
    this.memoryGb = 64,
    this.diskGb = 100,
  });

  final String gpu;
  final int gpuCount;
  final int cpu;
  final int memoryGb;
  final int diskGb;

  /// 卡名。多卡时带上张数(现在恒为 1,但下发的是个数字,别假设)。
  String get name => gpuCount > 1 ? '$gpu ×$gpuCount' : gpu;

  /// 副行规格:`14 核 · 64 GB · 100 GB SSD`。
  String get detail => '$cpu 核 · $memoryGb GB · $diskGb GB SSD';

  static RentalSpec? fromJson(Object? j) {
    if (j is! Map) return null;
    final gpu = j['gpu'];
    if (gpu is! String || gpu.isEmpty) return null;
    return RentalSpec(
      gpu: gpu,
      gpuCount: (j['gpu_count'] as num?)?.toInt() ?? 1,
      cpu: (j['cpu'] as num?)?.toInt() ?? 14,
      memoryGb: (j['memory_gb'] as num?)?.toInt() ?? 64,
      diskGb: (j['disk_gb'] as num?)?.toInt() ?? 100,
    );
  }
}

/// 服务端各项的兜底默认(拿不到 status 时用;正常路径一律以服务端下发为准)。
const kIdleChoicesFallback = <int>[180, 600, 1800, 0];
const kIdleDefaultFallback = 600;
const kMaxUptimeFallback = 4 * 3600;
const kRateFallback = 3.0;

/// 两段等待,**必须分开说**。它们发生在不同时刻,加起来写成一个数就会骗人
/// (服务端注释里专门记了这个教训:曾经合成 85,前端照着写「开机约一分半」)。
///  - [kBootHintFallback]:`start` 阻塞到服务就绪要多久(实测 36s);
///  - [kFirstImageHintFallback]:就绪后**第一张**图额外要多久(权重加载,实测 24s),
///    之后就快了。
const kBootHintFallback = 40;
const kFirstImageHintFallback = 25;

String idleLabel(int s) => s == 0 ? '不自动关' : '${s ~/ 60} 分钟';

/// 与服务端 `Rental.state` 对齐(none / creating / ready / ending / failed)。
enum RentalStatus { none, creating, ready, ending, failed }

RentalStatus _parseStatus(Object? v) => switch (v) {
  'creating' => RentalStatus.creating,
  'ready' => RentalStatus.ready,
  'ending' => RentalStatus.ending,
  'failed' => RentalStatus.failed,
  _ => RentalStatus.none,
};

class RentalState {
  const RentalState({
    this.status = RentalStatus.none,
    this.instanceId = '',
    this.idleSeconds = kIdleDefaultFallback,
    this.elapsedS = 0,
    this.price = 0,
    this.ratePerHour = kRateFallback,
    this.jobsDone = 0,
    this.jobsFailed = 0,
    this.note = '',
    this.fetchedAtMs = 0,
    this.idleChoices = kIdleChoicesFallback,
    this.idleDefault = kIdleDefaultFallback,
    this.maxUptimeS = kMaxUptimeFallback,
    this.bootHintS = kBootHintFallback,
    this.firstImageHintS = kFirstImageHintFallback,
    this.busy = false,
    this.error = '',
    this.authed = true,
    this.spec = const RentalSpec(),
  });

  final RentalStatus status;
  final String instanceId;
  final int idleSeconds;

  /// 服务端那一刻的已计费秒数与金额,以及取到它们的本地时刻(插值锚点)。
  final int elapsedS;
  final double price;
  final int fetchedAtMs;

  final double ratePerHour;
  final int jobsDone;
  final int jobsFailed;
  final String note;

  /// 服务端下发的可选项。
  final List<int> idleChoices;
  final int idleDefault;
  final int maxUptimeS;

  /// 开机到就绪 / 就绪后首张图,两段各自的预期秒数(见常量处的说明)。
  final int bootHintS;
  final int firstImageHintS;

  /// 开机 / 关机在途(开机会阻塞几十秒到几分钟,按钮期间不能再点)。
  final bool busy;
  final String error;

  /// 没有 Bot 会话:租卡整条路都不可用,面板据此给出去授权的提示。
  final bool authed;

  /// 机型(服务端下发;没到货前是占位)。
  final RentalSpec spec;

  bool get active =>
      status == RentalStatus.creating ||
      status == RentalStatus.ready ||
      status == RentalStatus.ending;

  /// 插值后的已计费秒数。服务端读数 + 距上次取到的时间差。
  ///
  /// **启动中恒为 0**:服务端 `billed_seconds` 在就绪前返回 0(没交付就不收),
  /// 就绪那一刻才跳到「含启动时长」的值。这个跳变是对的,不要在本地抹平。
  ///
  /// 插值只**往前**走:服务端那个读数是锚点也是下限。时钟回拨(用户改时间 /
  /// NTP 校正)时若让漂移变负,界面上的已计费时长会当着人面往回缩 ——
  /// 那比不走字更像出了错。
  int elapsedAt(int nowMs) {
    if (status != RentalStatus.ready) return elapsedS;
    final drift = fetchedAtMs == 0
        ? 0
        : ((nowMs - fetchedAtMs) ~/ 1000).clamp(0, 1 << 30);
    return elapsedS + drift;
  }

  double priceAt(int nowMs) => status != RentalStatus.ready
      ? price
      : elapsedAt(nowMs) / 3600.0 * ratePerHour;

  RentalState copyWith({
    RentalStatus? status,
    String? instanceId,
    int? idleSeconds,
    int? elapsedS,
    double? price,
    double? ratePerHour,
    int? jobsDone,
    int? jobsFailed,
    String? note,
    int? fetchedAtMs,
    List<int>? idleChoices,
    int? idleDefault,
    int? maxUptimeS,
    int? bootHintS,
    int? firstImageHintS,
    bool? busy,
    String? error,
    bool? authed,
    RentalSpec? spec,
  }) => RentalState(
    status: status ?? this.status,
    instanceId: instanceId ?? this.instanceId,
    idleSeconds: idleSeconds ?? this.idleSeconds,
    elapsedS: elapsedS ?? this.elapsedS,
    price: price ?? this.price,
    ratePerHour: ratePerHour ?? this.ratePerHour,
    jobsDone: jobsDone ?? this.jobsDone,
    jobsFailed: jobsFailed ?? this.jobsFailed,
    note: note ?? this.note,
    fetchedAtMs: fetchedAtMs ?? this.fetchedAtMs,
    idleChoices: idleChoices ?? this.idleChoices,
    idleDefault: idleDefault ?? this.idleDefault,
    maxUptimeS: maxUptimeS ?? this.maxUptimeS,
    bootHintS: bootHintS ?? this.bootHintS,
    firstImageHintS: firstImageHintS ?? this.firstImageHintS,
    busy: busy ?? this.busy,
    error: error ?? this.error,
    authed: authed ?? this.authed,
    spec: spec ?? this.spec,
  );

  /// 合入服务端返回的一份状态(status / start / idle 都是同一张 `public()` 视图)。
  RentalState merge(Map<String, dynamic> j, int nowMs) {
    final list = j['idle_choices'];
    return copyWith(
      status: _parseStatus(j['state']),
      instanceId: j['instance_id'] as String? ?? '',
      idleSeconds: (j['idle_timeout'] as num?)?.toInt() ?? idleSeconds,
      elapsedS: (j['elapsed_s'] as num?)?.toInt() ?? 0,
      price: (j['price'] as num?)?.toDouble() ?? 0,
      ratePerHour: (j['rate_per_hour'] as num?)?.toDouble() ?? ratePerHour,
      jobsDone: (j['jobs_done'] as num?)?.toInt() ?? 0,
      jobsFailed: (j['jobs_failed'] as num?)?.toInt() ?? 0,
      note: j['note'] as String? ?? '',
      fetchedAtMs: nowMs,
      idleChoices: list is List
          ? [
              for (final v in list)
                if (v is num) v.toInt(),
            ]
          : idleChoices,
      idleDefault: (j['idle_default'] as num?)?.toInt() ?? idleDefault,
      maxUptimeS: (j['max_uptime_s'] as num?)?.toInt() ?? maxUptimeS,
      bootHintS: (j['boot_hint_s'] as num?)?.toInt() ?? bootHintS,
      firstImageHintS:
          (j['first_image_hint_s'] as num?)?.toInt() ?? firstImageHintS,
      authed: true,
      spec: RentalSpec.fromJson(j['spec']) ?? spec,
    );
  }
}

/// Anima / Krea 的算力来源。免费 = 服务端共享 Modal 队列(排队,不花钱);
/// 独享 = 自己租的那台(不排队,按时长计费)。
enum ModalChannel { free, rented }

/// 通道 + 想用的空闲超时:这两样是用户偏好,持久化。
/// 实例的运行状态不进这里 —— 那是服务端的事实,由 [gpuRentalProvider] 现问。
class RentalPrefs {
  const RentalPrefs({
    this.channel = ModalChannel.free,
    this.idleSeconds = kIdleDefaultFallback,
  });

  final ModalChannel channel;
  final int idleSeconds;

  RentalPrefs copyWith({ModalChannel? channel, int? idleSeconds}) =>
      RentalPrefs(
        channel: channel ?? this.channel,
        idleSeconds: idleSeconds ?? this.idleSeconds,
      );

  factory RentalPrefs.fromJson(Map<String, dynamic> j) => RentalPrefs(
    channel: j['channel'] == 'rented' ? ModalChannel.rented : ModalChannel.free,
    idleSeconds: (j['idleSeconds'] as num?)?.toInt() ?? kIdleDefaultFallback,
  );

  Map<String, dynamic> toJson() => {
    'channel': channel == ModalChannel.rented ? 'rented' : 'free',
    'idleSeconds': idleSeconds,
  };
}

const _prefsKey = 'gpu_rental';

final rentalPrefsProvider =
    AsyncNotifierProvider<RentalPrefsNotifier, RentalPrefs>(
      RentalPrefsNotifier.new,
    );

class RentalPrefsNotifier extends AsyncNotifier<RentalPrefs> {
  PrefsStore get _storage => ref.read(prefsStoreProvider);

  @override
  Future<RentalPrefs> build() async {
    try {
      final raw = await _storage.read(key: _prefsKey);
      if (raw == null || raw.isEmpty) return const RentalPrefs();
      return RentalPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const RentalPrefs();
    }
  }

  /// 先改状态(立即生效),再尽力持久化(失败不打断创作)。
  Future<void> patch(RentalPrefs Function(RentalPrefs) change) async {
    final next = change(state.value ?? const RentalPrefs());
    state = AsyncData(next);
    try {
      await _storage.write(key: _prefsKey, value: jsonEncode(next.toJson()));
    } catch (_) {}
  }
}

final gpuRentalProvider = NotifierProvider<GpuRentalNotifier, RentalState>(
  GpuRentalNotifier.new,
);

class GpuRentalNotifier extends Notifier<RentalState> {
  Timer? _poll;

  /// 轮询间隔。服务端巡检 30s 一轮(空闲超时/硬上限就是那里执行的),
  /// app 侧比它快一点,机器被自动关掉后界面不会挂着一个假的「运行中」。
  static const _pollEvery = Duration(seconds: 20);

  String? get _session => ref.read(botSessionProvider).value?.sessionId;
  BackendClient get _client => ref.read(backendClientProvider);

  @override
  RentalState build() {
    // 回前台补一次:后台挂久了系统会压制定时器,那期间实例可能已被空闲超时
    // 关掉(或者反过来,用户在别处开了一台)。不补这一下,回来看到的是旧读数。
    final life = AppLifecycleListener(
      onStateChange: (s) {
        if (s == AppLifecycleState.resumed) unawaited(refresh());
      },
    );
    ref.onDispose(() {
      _poll?.cancel();
      life.dispose();
    });
    // 会话到货 / 掉线都要重问一次:没有会话时整条路不可用。
    // 冷启动时这一发就是「重进 app 还能看到自己那台」的来源 ——
    // 服务端 img_rentals.json 落盘 + _load() 恢复,状态一直在。
    ref.listen(botSessionProvider, (_, next) {
      final id = next.value?.sessionId;
      if (id == null || id.isEmpty) {
        _poll?.cancel();
        state = const RentalState(authed: false);
      } else {
        unawaited(refresh());
      }
    }, fireImmediately: true);
    return const RentalState();
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  void _rearm() {
    _poll?.cancel();
    if (!state.active) return;
    _poll = Timer(_pollEvery, refresh);
  }

  /// 拉一次状态。失败不清空已有读数 —— 网络抖一下就把运行中的实例显示成
  /// 「未启动」,用户会以为机器已经关了,那才是最贵的误导。
  Future<void> refresh() async {
    final sid = _session;
    if (sid == null || sid.isEmpty) {
      state = const RentalState(authed: false);
      return;
    }
    try {
      final j = await _client.rentalStatus(sid);
      if (j['ok'] != true) {
        state = state.copyWith(error: j['message'] as String? ?? '');
      } else {
        final next = state.merge(j, _now()).copyWith(error: '');
        // 开机在途时别被一次「还没登记上」的轮询打回未启动:start 那边是先
        // 落盘再建机器,理论上查得到,但两条请求赛跑不值得赌。以 start 的
        // 返回为准,轮询期间只允许它往前走(creating → ready)。
        state = (state.busy && next.status == RentalStatus.none) ? state : next;
      }
    } catch (e) {
      state = state.copyWith(error: '$e');
    }
    _rearm();
  }

  /// 开机。**服务端会一直阻塞到就绪**(约 85s,上限 300s),所以本地先进
  /// 「启动中」,请求回来才落地;期间按钮置忙,重复点不会开出第二台。
  Future<void> start(int idleSeconds) async {
    final sid = _session;
    if (sid == null || sid.isEmpty || state.busy || state.active) return;
    state = state.copyWith(
      status: RentalStatus.creating,
      busy: true,
      error: '',
      note: '',
      elapsedS: 0,
      price: 0,
      fetchedAtMs: _now(),
    );
    _rearm(); // 开机这 80 多秒也轮询:连接万一断了,状态仍旧跟得上
    try {
      final j = await _client.rentalStart(sid, idleTimeout: idleSeconds);
      state = j['ok'] == true
          // 这个调用是阻塞到就绪才返回的,所以「返回」就是「可以用了」
          ? state.merge(j, _now()).copyWith(busy: false)
          // 服务端明说失败:那边已经把实例销毁了,而且一分不收
          : state.copyWith(
              status: RentalStatus.failed,
              busy: false,
              note: j['message'] as String? ?? '开机失败',
            );
    } catch (e) {
      // ⚠ 客户端这边出错(断网 / 超时)**不等于没开成**:服务端很可能已经把
      // 机器建起来了,正在计费。直接标成「开机失败」会让用户以为什么都没发生,
      // 而那台机器在后台一路烧到 4 小时硬上限。所以回去问服务端,以它为准。
      state = state.copyWith(busy: false, error: '$e');
      await refresh();
      if (!state.active) {
        state = state.copyWith(status: RentalStatus.failed, note: '$e');
      }
      return;
    }
    _rearm();
  }

  /// 关机结账。返回服务端给的结账摘要(秒数 / 金额 / 出图张数),供 UI 回执。
  Future<Map<String, dynamic>?> stop() async {
    final sid = _session;
    if (sid == null || sid.isEmpty || state.busy || !state.active) return null;
    state = state.copyWith(status: RentalStatus.ending, busy: true, error: '');
    try {
      final j = await _client.rentalStop(sid);
      state = const RentalState().copyWith(
        idleChoices: state.idleChoices,
        idleDefault: state.idleDefault,
        maxUptimeS: state.maxUptimeS,
        bootHintS: state.bootHintS,
        ratePerHour: state.ratePerHour,
      );
      unawaited(refresh());
      return j['ok'] == true ? j : null;
    } catch (e) {
      state = state.copyWith(busy: false, error: '$e');
      unawaited(refresh());
      return null;
    }
  }

  /// 改空闲自动关机时长。运行中即时生效;没在跑就只记偏好(下次开机带上)。
  Future<void> setIdle(int seconds) async {
    await ref
        .read(rentalPrefsProvider.notifier)
        .patch((p) => p.copyWith(idleSeconds: seconds));
    if (!state.active) {
      state = state.copyWith(idleSeconds: seconds);
      return;
    }
    final sid = _session;
    if (sid == null || sid.isEmpty) return;
    state = state.copyWith(idleSeconds: seconds); // 先落地,失败再由轮询拉回
    try {
      final j = await _client.rentalSetIdle(sid, seconds);
      if (j['ok'] == true) state = state.merge(j, _now());
    } catch (_) {
      unawaited(refresh());
    }
  }

  /// 失败态是个死胡同,给个「知道了」的出口回到未启动。
  void dismissFailure() {
    if (state.status == RentalStatus.failed) {
      state = state.copyWith(status: RentalStatus.none, note: '', error: '');
    }
  }
}

/// 计时读数 `12:34` / `1:02:03`。
String fmtUptime(int seconds) {
  final s = seconds.clamp(0, 1 << 30);
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 金额读数:两位小数带 ¥。
String fmtYuan(double v) => '¥${v.toStringAsFixed(2)}';
