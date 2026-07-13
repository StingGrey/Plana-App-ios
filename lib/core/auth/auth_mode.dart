import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// 接入方式。`token` = 自带 NAI 令牌直连;`bot` = 通过后端 Bot 授权。
enum AuthMode { token, bot }

const _modeKey = 'auth_mode';

/// 当前接入方式;`null` = 尚未选择(首启走引导页)。
final authModeProvider =
    AsyncNotifierProvider<AuthModeNotifier, AuthMode?>(AuthModeNotifier.new);

class AuthModeNotifier extends AsyncNotifier<AuthMode?> {
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  @override
  Future<AuthMode?> build() async {
    try {
      final v = await _storage.read(key: _modeKey);
      return switch (v) {
        'token' => AuthMode.token,
        'bot' => AuthMode.bot,
        _ => null,
      };
    } catch (_) {
      return null; // Keystore 未就绪按「未选择」处理,不崩
    }
  }

  Future<void> set(AuthMode mode) async {
    try {
      await _storage.write(key: _modeKey, value: mode.name);
      state = AsyncData(mode);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// 清除选择,退回引导页。
  Future<void> reset() async {
    try {
      await _storage.delete(key: _modeKey);
    } catch (_) {}
    state = const AsyncData(null);
  }
}
