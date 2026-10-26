import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/data/trans_cache_store.dart';

/// 后端翻回来的译名存到本机:写盘、开机灌回反查缓存、条数封顶。
void main() {
  // 反查缓存是顶层全局,各用例用互不重叠的生造词。
  Directory tmp() {
    final d = Directory.systemTemp.createTempSync('trans_cache');
    addTearDown(() => d.deleteSync(recursive: true));
    return d;
  }

  test('落盘后,新开一份载入就能反查到', () async {
    final root = tmp();
    final a = TransCacheStore(root);
    a.put('zzq pearl necklace hanging', '垂挂珍珠项链');
    a.flush();
    await a.idle;

    final b = TransCacheStore(root);
    await b.load();
    expect(b.length, 1);
    expect(translationOf('zzq pearl necklace hanging'), '垂挂珍珠项链');
  });

  test('没有改动时 flush 不写盘', () async {
    final root = tmp();
    final s = TransCacheStore(root);
    s.flush();
    await s.idle;
    expect(File('${root.path}/tag_trans_cache.json').existsSync(), isFalse);
  });

  test('超过上限丢最早的', () async {
    final root = tmp();
    final a = TransCacheStore(root);
    for (var i = 0; i < TransCacheStore.cap + 10; i++) {
      a.put('zzq cap $i', '译$i');
    }
    a.flush();
    await a.idle;

    final saved =
        jsonDecode(File('${root.path}/tag_trans_cache.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(saved, hasLength(TransCacheStore.cap));
    expect(saved.containsKey('zzq cap 0'), isFalse);
    expect(
      saved['zzq cap ${TransCacheStore.cap + 9}'],
      '译${TransCacheStore.cap + 9}',
    );
  });

  test('翻译服务把后端翻出来的存进本机,查过没有的不存', () async {
    final root = tmp();
    final store = TransCacheStore(root);
    const hit = 'zzq livestream interface';
    const miss = 'zzq qqxx';
    final svc = TagTranslationService(
      enabled: true,
      baseUrl: 'https://x.test',
      saved: store,
      client: MockClient(
        (req) async => http.Response(
          jsonEncode({
            'translations': {hit: '直播界面'},
            'missing': [miss],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    addTearDown(svc.dispose);

    svc.request([hit, miss]);
    await Future<void>.delayed(const Duration(milliseconds: 900)); // 防抖 700ms
    store.flush();
    await store.idle;

    final saved =
        jsonDecode(File('${root.path}/tag_trans_cache.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(saved, {hit: '直播界面'});
  });
}
