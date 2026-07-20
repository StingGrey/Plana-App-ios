import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/auth/bot_session_store.dart';
import '../../../core/auth/secure_storage.dart';

/// 补全来源。
///  - `enhanced`:走后端 `/api/tags/*`(Danbooru 代理 + 中文翻译 + 中文搜词),需 Bot 授权。
///  - `danbooru`:内置离线 Danbooru 词库(含中文),本地匹配、不联网(手机直连被 Cloudflare 挡死,改离线)。
enum CompletionSource { enhanced, danbooru }

const _key = 'completion_source';

/// 用户在设置里显式选择的补全来源;`null` = 未选(跟随账户默认)。
final completionSourcePrefProvider =
    AsyncNotifierProvider<CompletionSourcePrefNotifier, CompletionSource?>(
      CompletionSourcePrefNotifier.new,
    );

class CompletionSourcePrefNotifier extends AsyncNotifier<CompletionSource?> {
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  @override
  Future<CompletionSource?> build() async {
    try {
      final v = await _storage.read(key: _key);
      return switch (v) {
        'enhanced' => CompletionSource.enhanced,
        'danbooru' => CompletionSource.danbooru,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> set(CompletionSource source) async {
    try {
      await _storage.write(key: _key, value: source.name);
      state = AsyncData(source);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

/// 生效补全来源。增强补全是纯后端功能,只看**有没有 Bot 会话**——
/// 与生成走直连 Token 还是走后端无关(自带 Token 的用户授权 Bot 后一样能用)。
/// 没有会话则一律离线词库;有会话默认增强,可在设置切换。
final effectiveCompletionSourceProvider = Provider<CompletionSource>((ref) {
  if (ref.watch(botSessionProvider).value == null) {
    return CompletionSource.danbooru;
  }
  final pref = ref.watch(completionSourcePrefProvider).value;
  return pref ?? CompletionSource.enhanced;
});
