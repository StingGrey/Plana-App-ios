import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/credential_store.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';

/// 加密存储留不住数据的机型(每次冷启动整份被清)要改存
/// 文件,正常机型照旧走加密存储。两边判错都要命:漏判 = 每次冷启动丢 Key;
/// 误判 = 好好的机器丢了 Keystore 这层保护,还白白提示一次「Key 被清了」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_cred');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  /// 一次冷启动重新读 `settings.json`(迁移那步不碰加密存储)。
  Future<PrefsStore> boot() => PrefsStore.open(
    root,
    legacyRead: (_) async => null,
    legacyDelete: (_) async {},
  );

  Future<CredentialStore> open(PrefsStore p, {FlutterSecureStorage? secure}) =>
      CredentialStore.open(
        p,
        root: root,
        secure: secure ?? const FlutterSecureStorage(),
      );

  const keystore = FlutterSecureStorage();
  const primed = '{"notifyPrimed":true}';

  /// 用过一阵的老用户:种过暗号、走完过引导、选的直连。
  Future<PrefsStore> veteran() async {
    final p = await boot();
    await p.write(key: CredentialStore.canaryKey, value: 'abc');
    await p.write(key: 'gen_settings', value: primed);
    await p.write(key: kAuthModeKey, value: 'token');
    return p;
  }

  test('全新安装:种下暗号,照旧走加密存储', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final p = await boot();
    final c = await open(p);

    expect(c.usesFile, isFalse);
    final mark = p.get(CredentialStore.canaryKey);
    expect(mark, isNotNull);
    expect(await keystore.read(key: CredentialStore.canaryKey), mark);
    await c.write(key: 'nai_access_keys', value: '[1]');
    expect(await keystore.read(key: 'nai_access_keys'), '[1]');
    expect(c.takeLostNotice(), isFalse);
  });

  test('暗号对得上:照旧走加密存储', () async {
    final p = await veteran();
    FlutterSecureStorage.setMockInitialValues({
      CredentialStore.canaryKey: 'abc',
      'nai_access_keys': '[1]',
    });
    final c = await open(p);

    expect(c.usesFile, isFalse);
    expect(await c.read(key: 'nai_access_keys'), '[1]');
    expect(c.takeLostNotice(), isFalse);
  });

  test('加密存储整份被清:改存文件、提示一次,此后一直走文件', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final c = await open(await veteran());

    expect(c.usesFile, isTrue);
    expect(c.takeLostNotice(), isTrue);
    expect(c.takeLostNotice(), isFalse, reason: '只提示一次');
    await c.write(key: 'nai_access_keys', value: '[1]');

    // 下一次冷启动加密存储照样被清,Key 还在,也不再提示
    FlutterSecureStorage.setMockInitialValues({});
    final again = await open(await boot());
    expect(again.usesFile, isTrue);
    expect(await again.read(key: 'nai_access_keys'), '[1]');
    expect(again.takeLostNotice(), isFalse);
  });

  test('升级后头一次启动:引导走完过却没有接入方式 → 认定被清,补上直连', () async {
    final p = await boot();
    await p.write(key: 'gen_settings', value: primed);
    FlutterSecureStorage.setMockInitialValues({});
    final c = await open(p);

    expect(c.usesFile, isTrue);
    expect(p.get(kAuthModeKey), 'token', reason: '不补的话又被踢回引导页');
    expect(c.takeLostNotice(), isTrue);
  });

  test('升级后头一次启动,加密存储正常:种暗号,不改存', () async {
    final p = await boot();
    await p.write(key: 'gen_settings', value: primed);
    await p.write(key: kAuthModeKey, value: 'bot'); // 刚从加密存储迁出来
    FlutterSecureStorage.setMockInitialValues({'bot_session': '{}'});
    final c = await open(p);

    expect(c.usesFile, isFalse);
    expect(p.get(CredentialStore.canaryKey), isNotNull);
    expect(p.get(kAuthModeKey), 'bot');
    expect(await c.read(key: 'bot_session'), '{}');
  });

  test('自己 deleteAll 不算「被系统清过」:暗号留着,下次照旧走加密存储', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final p = await boot();
    final c = await open(p);
    await c.write(key: 'nai_access_keys', value: '[1]');
    await c.deleteAll();

    expect(await c.readAll(), isEmpty, reason: '暗号不对外露');
    expect(await keystore.read(key: 'nai_access_keys'), isNull);
    final again = await open(await boot());
    expect(again.usesFile, isFalse);
    expect(again.takeLostNotice(), isFalse);
  });

  test('暗号对不上但数据都在(种暗号那次进程被杀):搬进文件,不提示', () async {
    final p = await veteran();
    FlutterSecureStorage.setMockInitialValues({'nai_access_keys': '[1]'});
    final c = await open(p);

    expect(c.usesFile, isTrue);
    expect(await c.read(key: 'nai_access_keys'), '[1]');
    expect(c.takeLostNotice(), isFalse);
  });

  test('加密存储一碰就抛:改存文件,照常读写', () async {
    final c = await open(await veteran(), secure: _Broken());

    expect(c.usesFile, isTrue);
    expect(c.takeLostNotice(), isTrue);
    await c.write(key: 'bot_session', value: 's');
    expect(await c.read(key: 'bot_session'), 's');
  });

  test('全新安装就写不进加密存储:直接走文件,不提示', () async {
    final c = await open(await boot(), secure: _Broken());

    expect(c.usesFile, isTrue);
    expect(c.takeLostNotice(), isFalse);
  });

  test('接入方式存在 settings.json,不进加密存储', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final stores = AppStores.ephemeral();
    final c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(c.dispose);

    await c.read(authModeProvider.future);
    await c.read(authModeProvider.notifier).set(AuthMode.bot);
    expect(stores.prefs.get(kAuthModeKey), 'bot');
    expect(await keystore.read(key: kAuthModeKey), isNull);
  });
}

/// Keystore 彻底用不了的机器:读写都抛。
class _Broken extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw StateError('keystore');

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
  }) async => throw StateError('keystore');

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw StateError('keystore');
}
