import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// 本机加密存储的 NovelAI 访问令牌(v1 直连 NAI 用)。
/// 生成链路后续从 [tokenProvider] 读取此值作为 Authorization。
const _tokenKey = 'nai_access_token';

final tokenProvider = AsyncNotifierProvider<TokenNotifier, String?>(
  TokenNotifier.new,
);

/// 已保存的 NAI Key 全集 —— **今天只存一把**,所以长度只会是 0 或 1。
///
/// 单独开这个出处是给直连模式的并行用的:并发上限就是它的长度,「每条任务
/// 独占一把 Key」也按它分配。NAI 是**按账号限流**的,同一把 Key 并发只会
/// 自己打自己(429),所以上限不能拍脑袋给个常数。
/// 将来支持存多把时只改这里,并发闸门与分配逻辑一行都不用动。
final naiKeysProvider = FutureProvider<List<String>>((ref) async {
  final t = await ref.watch(tokenProvider.future);
  return (t == null || t.isEmpty) ? const <String>[] : <String>[t];
});

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
