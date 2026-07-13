import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/secure_storage.dart';

/// Plana 后端基址(可编辑设置)。形如 `https://nai.sora214.top`,末尾无斜杠;
/// `/api` 前缀由 client 补,WS 由 `^http`→`ws` 推出(`https`→`wss`)。
/// 默认内置官方后端;用户可在引导/我的页改成自建局域网地址。
const kDefaultBackendBase = 'https://nai.sora214.top';

const _backendKey = 'backend_base_url';

final backendBaseProvider =
    AsyncNotifierProvider<BackendBaseNotifier, String>(BackendBaseNotifier.new);

class BackendBaseNotifier extends AsyncNotifier<String> {
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  @override
  Future<String> build() async {
    try {
      final v = await _storage.read(key: _backendKey);
      // 空/未存都回退内置默认(否则旧的空串会盖掉默认地址)。
      return normalize((v == null || v.trim().isEmpty) ? kDefaultBackendBase : v);
    } catch (_) {
      return kDefaultBackendBase;
    }
  }

  Future<void> save(String url) async {
    final u = normalize(url);
    try {
      await _storage.write(key: _backendKey, value: u);
      state = AsyncData(u);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// trim + 去尾斜杠。
  static String normalize(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}
