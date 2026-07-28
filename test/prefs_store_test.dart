import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/prefs_store.dart';

/// S1C-11 的回归:9 类非机密设置从 secure storage 迁到 `settings.json`。
///
/// 迁移是**一次性且不可逆**的(搬完就把 secure storage 里那份删了),
/// 老用户升级时跑错一次设置就没了,所以这里逐条钉死。
void main() {
  Directory tmp() {
    final d = Directory.systemTemp.createTempSync('plana_prefs');
    addTearDown(() => d.deleteSync(recursive: true));
    return d;
  }

  test('首次启动:从 secure storage 搬过来,并把原处删掉', () async {
    final root = tmp();
    final legacy = <String, String>{
      'theme_settings': '{"mode":"dark"}',
      'gen_settings': '{"steps":28}',
      'nai_access_token': 'pst-secret', // 凭据:不在迁移名单里,不该被碰
    };
    final deleted = <String>[];

    final prefs = await PrefsStore.open(
      root,
      legacyRead: (k) async => legacy[k],
      legacyDelete: (k) async {
        deleted.add(k);
        legacy.remove(k);
      },
    );

    expect(await prefs.read(key: 'theme_settings'), '{"mode":"dark"}');
    expect(await prefs.read(key: 'gen_settings'), '{"steps":28}');
    expect(deleted, containsAll(['theme_settings', 'gen_settings']));

    // 凭据必须原封不动留在 secure storage
    expect(legacy['nai_access_token'], 'pst-secret');
    expect(deleted, isNot(contains('nai_access_token')));

    // 落了盘,下次启动不必再迁
    final onDisk = jsonDecode(
      File('${root.path}/settings.json').readAsStringSync(),
    );
    expect(onDisk['theme_settings'], '{"mode":"dark"}');
  });

  test('二次启动:本地已有就不再回头读 secure storage', () async {
    final root = tmp();
    File('${root.path}/settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'theme_settings': 'local'}));

    var reads = 0;
    final prefs = await PrefsStore.open(
      root,
      legacyRead: (k) async {
        reads++;
        return k == 'theme_settings' ? 'stale' : null;
      },
      legacyDelete: (_) async {},
    );

    expect(await prefs.read(key: 'theme_settings'), 'local', reason: '本地值优先');
    expect(
      reads,
      PrefsStore.migrateKeys.length - 1,
      reason: '已存在的键应被跳过,不再读 secure storage',
    );
  });

  test('某一项读不出来(Keystore 故障)不连累其余项', () async {
    final root = tmp();
    final prefs = await PrefsStore.open(
      root,
      legacyRead: (k) async {
        if (k == 'gen_settings') throw StateError('keystore boom');
        return k == 'theme_settings' ? 'ok' : null;
      },
      legacyDelete: (_) async {},
    );
    expect(await prefs.read(key: 'theme_settings'), 'ok');
    expect(await prefs.read(key: 'gen_settings'), isNull);
  });

  test('写入落盘并可重新读回;delete 清掉', () async {
    final root = tmp();
    final a = await PrefsStore.open(
      root,
      legacyRead: (_) async => null,
      legacyDelete: (_) async {},
    );
    await a.write(key: 'save_settings', value: '{"fmt":"png"}');

    final b = await PrefsStore.open(
      root,
      legacyRead: (_) async => null,
      legacyDelete: (_) async {},
    );
    expect(await b.read(key: 'save_settings'), '{"fmt":"png"}');

    await b.delete(key: 'save_settings');
    final c = await PrefsStore.open(
      root,
      legacyRead: (_) async => null,
      legacyDelete: (_) async {},
    );
    expect(await c.read(key: 'save_settings'), isNull);
  });

  test('settings.json 损坏时按默认起步,不崩', () async {
    final root = tmp();
    File('${root.path}/settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{oops');
    final prefs = await PrefsStore.open(
      root,
      legacyRead: (_) async => null,
      legacyDelete: (_) async {},
    );
    expect(await prefs.read(key: 'theme_settings'), isNull);
  });

  test('凭据三项不在迁移名单里(防止有人手滑加进去)', () {
    expect(PrefsStore.migrateKeys, isNot(contains('nai_access_token')));
    expect(PrefsStore.migrateKeys, isNot(contains('bot_session')));
    expect(PrefsStore.migrateKeys, isNot(contains('auth_mode')));
  });
}
