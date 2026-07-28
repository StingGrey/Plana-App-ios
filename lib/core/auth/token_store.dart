import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// 本机加密存储的 NovelAI 访问令牌(v1 直连 NAI 用)。
/// 生成链路后续从 [tokenProvider] 读取此值作为 Authorization。
const _tokenKey = 'nai_access_token';

final tokenProvider = AsyncNotifierProvider<TokenNotifier, String?>(
  TokenNotifier.new,
);

class TokenNotifier extends AsyncNotifier<String?> {
  // 必须用共享的 secureStorageProvider,不能自建一个:两者当前配置相同,
  // 但一旦给共享那个加上 AndroidOptions(resetOnError 等),自建的这份会是
  // **唯一没跟上的**,而且编译器和 lint 都不会提醒。见 S1A-04。
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  @override
  Future<String?> build() async {
    try {
      final t = await _storage.read(key: _tokenKey);
      return (t == null || t.isEmpty) ? null : t;
    } catch (_) {
      // Keystore 尚未就绪 / 读取异常 —— 按「未设置」处理,不崩。
      return null;
    }
  }

  /// 保存(空串等同清除)。写失败时把状态标为 error 让页面提示。
  Future<void> save(String token) async {
    final t = token.trim();
    if (t.isEmpty) {
      await clear();
      return;
    }
    try {
      await _storage.write(key: _tokenKey, value: t);
      state = AsyncData(t);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {
      // 删除失败也把内存态清空,避免残留显示。
    }
    state = const AsyncData(null);
  }
}
