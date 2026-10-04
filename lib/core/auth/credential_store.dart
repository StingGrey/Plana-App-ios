import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../store/gen_settings.dart';
import '../store/prefs_store.dart';
import '../util/log.dart';
import 'auth_mode.dart';
import 'secure_storage.dart';

/// 凭据(NAI Key、Bot 会话、助手自填接口)的读写出口。平时就是 Keystore 加密
/// 存储;这台机被证实留不住加密存储之后,改存支持目录里的 [fileName],不再回头。
///
/// **为什么要这条退路**:flutter_secure_storage 冷启动解不开 Keystore 里的密钥时,
/// 默认的 `resetOnError` 会把整份加密存储清空,而且不报错。有的机型(群友的
/// OPPO A93 5G)每次冷启动都这样:进程内一切正常,一清后台凭据就没了。
///
/// **怎么认出来**:`settings.json` 与加密存储各放一份同样的随机暗号([canaryKey]),
/// 启动时两边对不上(加密存储那份没了或读不出来)就是被清过。升级上来的第一次
/// 启动还没有暗号,改用「引导走完过,接入方式却没能从加密存储迁出来」认 ——
/// 正是改之前反复弹引导的那个现场。
///
/// 继承 [FlutterSecureStorage] 只为让各读写点(都经 [secureStorageProvider])
/// 一行不改。加密档原样转给 [_secure];各读写点从不传平台参数,这里也不往下传。
class CredentialStore extends FlutterSecureStorage {
  CredentialStore._(this._secure, this._file, {this._lost = false});

  final FlutterSecureStorage _secure;

  /// 非空 = 已改存文件(复用 [PrefsStore] 的整表读写:原子落盘、串行写)。
  final PrefsStore? _file;

  bool _lost;

  /// `settings.json` 里的标记:改存文件后记 `file`,此后每次启动直接走文件。
  static const backendKey = 'cred_backend';

  /// 暗号,`settings.json` 与加密存储里各一份。
  static const canaryKey = 'cred_canary';

  static const fileName = 'credentials.json';

  bool get usesFile => _file != null;

  /// 本次启动认定「加密存储被清过,且什么都没救回来」时为真;取一次就清掉,
  /// 只提示一次。
  bool takeLostNotice() {
    final v = _lost;
    _lost = false;
    return v;
  }

  /// 必须在 [PrefsStore.open] 之后:判定要用到它刚从加密存储迁出来的接入方式。
  /// 任何一步出意外都照旧用加密存储,不挡启动。
  static Future<CredentialStore> open(
    PrefsStore prefs, {
    Directory? root,
    FlutterSecureStorage secure = kSecureStorage,
  }) async {
    try {
      final dir = root ?? await getApplicationSupportDirectory();
      final file = File('${dir.path}/$fileName');
      if (prefs.get(backendKey) == 'file') {
        return CredentialStore._(secure, await PrefsStore.openFile(file));
      }
      final mark = prefs.get(canaryKey);
      String? seen;
      var unreadable = false;
      try {
        seen = await secure.read(key: canaryKey);
      } catch (_) {
        unreadable = true;
      }
      final wiped = mark != null
          ? unreadable || seen != mark
          : notifyPrimedIn(prefs) && prefs.get(kAuthModeKey) == null;
      if (!wiped && await _plant(prefs, secure, mark)) {
        return CredentialStore._(secure, null);
      }
      return await _fallBack(prefs, secure, file, wiped: wiped);
    } catch (e) {
      logi('[cred] 启动检查失败,照旧用加密存储: ${e.runtimeType}');
      return CredentialStore._(secure, null);
    }
  }

  /// 没种过就种上。先写加密存储、再写 `settings.json` —— 反过来的话,前一笔
  /// 没写成会在下次启动被误判成「被清过」。加密存储写不进去说明这台机的
  /// Keystore 用不了,返回 false 改走文件。
  static Future<bool> _plant(
    PrefsStore prefs,
    FlutterSecureStorage secure,
    String? mark,
  ) async {
    if (mark != null) return true;
    final rnd = Random.secure();
    final v = [
      for (var i = 0; i < 16; i++)
        rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    try {
      await secure.write(key: canaryKey, value: v);
    } catch (_) {
      return false;
    }
    await prefs.write(key: canaryKey, value: v);
    return true;
  }

  static Future<CredentialStore> _fallBack(
    PrefsStore prefs,
    FlutterSecureStorage secure,
    File file, {
    required bool wiped,
  }) async {
    final store = await PrefsStore.openFile(file);
    // 读得出来的先搬过来:暗号对不上也可能只是种暗号那次进程被杀(加密存储的
    // 落盘慢半拍),那时数据其实都还在,不该让用户重填。
    var rescued = 0;
    try {
      for (final e in (await secure.readAll()).entries) {
        if (e.key == canaryKey) continue;
        if (e.key == kAuthModeKey) {
          // 没能迁进 settings.json 的接入方式,归位到它该在的地方
          if (prefs.get(kAuthModeKey) == null) {
            await prefs.write(key: kAuthModeKey, value: e.value);
          }
          continue;
        }
        // 还没迁走的老设置项归 PrefsStore 管,它每次启动自己会再试
        if (PrefsStore.migrateKeys.contains(e.key)) continue;
        await store.write(key: e.key, value: e.value);
        rescued++;
      }
    } catch (_) {}
    await prefs.write(key: backendKey, value: 'file');
    final primed = notifyPrimedIn(prefs);
    // 走完过引导的人,接入方式也跟着没了:按直连补上,免得再走一遍引导。
    // Bot 用户去「账号与接入」切回去即可。
    if (primed && prefs.get(kAuthModeKey) == null) {
      await prefs.write(key: kAuthModeKey, value: AuthMode.token.name);
    }
    logi(
      '[cred] 加密存储${wiped ? '被清过' : '写不进去'},凭据改存本机文件(救回 $rescued 项)',
    );
    return CredentialStore._(
      secure,
      store,
      lost: wiped && primed && rescued == 0,
    );
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _file?.read(key: key) ?? _secure.read(key: key);

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      _file?.write(key: key, value: value) ??
      _secure.write(key: key, value: value);

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _file?.delete(key: key) ?? _secure.delete(key: key);

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final f = _file;
    if (f != null) return f.get(key) != null;
    return _secure.containsKey(key: key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final f = _file;
    if (f != null) return f.snapshot();
    return {...await _secure.readAll()}..remove(canaryKey);
  }

  /// 加密档逐条删、留下暗号 —— 整份清掉的话,下次启动会被当成「被系统清过」。
  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final f = _file;
    if (f != null) return f.clear();
    for (final k in [...(await _secure.readAll()).keys]) {
      if (k != canaryKey) await _secure.delete(key: k);
    }
  }
}
