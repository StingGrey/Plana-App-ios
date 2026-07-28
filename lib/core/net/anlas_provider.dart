import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_mode.dart';
import '../auth/token_store.dart';
import 'backend_client.dart';
import 'backend_config.dart';
import 'nai_client.dart';

/// 点数信息(Anlas + 是否 Opus)。按接入方式取源:
///  - token 直连:NAI `/user/subscription`(用户账户剩余 Anlas)。
///  - bot 授权:后端 `/api/anlas`(共享服务账户余额,对齐 web,isOpus 恒 true)。
/// 模式/令牌/后端地址变化自动重拉;失败回退 null。
final anlasProvider = AsyncNotifierProvider<AnlasNotifier, NaiSubscription?>(
  AnlasNotifier.new,
);

class AnlasNotifier extends AsyncNotifier<NaiSubscription?> {
  @override
  Future<NaiSubscription?> build() async {
    // await 依赖(而非取 .value):懒加载 storage 首读期间 .value 是 null,
    // 会先空跑一轮返回 null、再等重建,首帧点数/Opus 状态平白慢一拍。
    final mode = await ref.watch(authModeProvider.future);
    if (mode == AuthMode.bot) {
      final base = await ref.watch(backendBaseProvider.future);
      if (base.isEmpty) return null;
      try {
        final anlas = await ref.read(backendClientProvider).getAnlas();
        return (anlas: anlas, isOpus: true, tier: 3);
      } catch (_) {
        return null;
      }
    }
    final token = await ref.watch(tokenProvider.future);
    if (token == null || token.isEmpty) return null;
    try {
      return await ref.read(naiClientProvider).subscription(token);
    } catch (_) {
      return null;
    }
  }

  /// 主动刷新(顶栏点按 / 生成后):**静默**拉新,成功才替换。
  /// 不置 loading——那会让所有消费端瞬间丢值:点数闪没、isOpus 丢失导致
  /// 免费图的费用胶囊闪现 20 Anlas 再变回免费(真机反馈修复)。
  Future<void> refresh() async {
    try {
      final mode = ref.read(authModeProvider).value;
      final NaiSubscription? next;
      if (mode == AuthMode.bot) {
        final base = await ref.read(backendBaseProvider.future);
        if (base.isEmpty) return;
        final anlas = await ref.read(backendClientProvider).getAnlas();
        next = (anlas: anlas, isOpus: true, tier: 3);
      } else {
        final token = await ref.read(tokenProvider.future);
        if (token == null || token.isEmpty) return;
        next = await ref.read(naiClientProvider).subscription(token);
      }
      state = AsyncData(next);
    } catch (_) {} // 拉失败保留旧值(旧行为会把显示清掉,更糟)
  }
}
