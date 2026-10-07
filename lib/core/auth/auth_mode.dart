import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/app_stores.dart';
import '../store/prefs_store.dart';

/// 接入方式。`token` = 自带 NAI 令牌直连;`bot` = 通过后端 Bot 授权。
enum AuthMode { token, bot }

/// 存在 `settings.json`,不在加密存储里 —— 它不是机密,而加密存储在有的机型上
/// 冷启动会被整份清掉(见 `CredentialStore`),放那边就等于每次都被踢回首启引导。
/// 老用户由 [PrefsStore.migrateKeys] 在启动时搬过来。
const kAuthModeKey = 'auth_mode';

/// 当前接入方式;`null` = 尚未选择(首启走引导页)。
final authModeProvider = AsyncNotifierProvider<AuthModeNotifier, AuthMode?>(
  AuthModeNotifier.new,
);

class AuthModeNotifier extends AsyncNotifier<AuthMode?> {
  PrefsStore get _prefs => ref.read(prefsStoreProvider);

  @override
  Future<AuthMode?> build() async {
    try {
      return switch (await _prefs.read(key: kAuthModeKey)) {
        'token' => AuthMode.token,
        'bot' => AuthMode.bot,
        _ => null,
      };
    } catch (_) {
      return null; // 无 AppStores(测试)按「未选择」处理,不崩
    }
  }

  Future<void> set(AuthMode mode) async {
    try {
      await _prefs.write(key: kAuthModeKey, value: mode.name);
      state = AsyncData(mode);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// 清除选择,退回引导页。
  Future<void> reset() async {
    try {
      await _prefs.delete(key: kAuthModeKey);
    } catch (_) {}
    state = const AsyncData(null);
  }
}
