import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart' show loraBaseOf;

/// 当前创作页模型该用哪个 LoRA 库(`anima` / `krea`)。
///
/// 两边权重互不通用,挂错了 ComfyUI 不报错、只是静默无效 —— 所以库从列表这层
/// 就按底模裁开。管理器、卡片、下载全程读这一份,不各自从模型名再推一遍。
final loraBaseProvider = Provider<String>(
  (ref) =>
      loraBaseOf(ref.watch(generateProvider.select((s) => s.params.model))),
);

/// 机房已装 LoRA 全集(`GET /api/lora/list?base=…`;「我的库」= 其中 favorited 的)。
///
/// **常驻**(不加 `.autoDispose`,riverpod 3 里普通 provider 默认就不自动释放):
/// 管理器关掉再打开不重拉一遍全集,与公共 Vibe / 灵感公共库同一范式。
/// 按 base 分族缓存 —— 在 Anima 与 Krea 之间来回切时两份各自留着,不互相冲掉。
/// 收藏关系变更走 [patch] / [dropByName] 就地回写,不整表刷新;
/// 只有下载完新条目和用户点刷新才 [reload]。
///
/// 未授权时抛 `StateError('need-bot')`,UI 据此显示授权提示(同 publicVibesProvider)。
final installedLorasProvider =
    AsyncNotifierProvider.family<InstalledLoras, List<LoraCardInfo>, String>(
      InstalledLoras.new,
    );

class InstalledLoras extends AsyncNotifier<List<LoraCardInfo>> {
  InstalledLoras(this.base);

  /// 底模归属(`anima` / `krea`),即家族键。
  final String base;

  @override
  Future<List<LoraCardInfo>> build() => _fetch();

  Future<List<LoraCardInfo>> _fetch() async {
    // watch:换账号 / 掉登录会自动重建,不用页面自己盯
    final session = await ref.watch(botSessionProvider.future);
    if (session == null) throw StateError('need-bot');
    return ref
        .read(backendClientProvider)
        .listLoras(session.sessionId, base: base);
  }

  /// 重新拉取。走 invalidateSelf 而不是自己 `state = AsyncLoading()`:
  /// 前者由 riverpod 保留上一份值(isLoading 为真但 hasValue 仍成立),
  /// 刷新时列表不闪空、失败也不掀桌。
  Future<void> reload() async {
    ref.invalidateSelf();
    try {
      await future; // 只为等它落定;错误本身已经进 state,由 UI 呈现
    } catch (_) {}
  }

  List<LoraCardInfo> get _list => state.value ?? const [];

  /// 收藏关系就地更新([LoraCardInfo] 不可变,重建该条)。
  void patch(String name, {bool? favorited, int? favoriteCount}) {
    final i = _list.indexWhere((x) => x.name == name);
    if (i < 0) return;
    final next = [..._list];
    next[i] = _list[i].copyWith(
      favorited: favorited,
      favoriteCount: favoriteCount,
    );
    state = AsyncData(next);
  }

  /// 后端已回收该条目(最后一个收藏者移出):从全集里摘掉。
  void dropByName(String name) {
    if (!_list.any((x) => x.name == name)) return;
    state = AsyncData([
      for (final x in _list)
        if (x.name != name) x,
    ]);
  }
}
