// 补全里「角色 / 作品类目的 tag 各自归组」这条路由。
//
// 两条来源两套 category 写法:autocomplete 给数字(4=character、3=copyright)、
// 语义搜索给字符串('Character'/'Copyright')。认错任何一条,角色和作品就会混在
// 几十条普通标签里 —— 那正是加这个分组前的样子。
//
// 2026-08-25 起本地 role_tag_mapping.json 从补全链路退役,角色与作品**全量**
// 来自上游,所以这两条映射是唯一来源,错了就整组消失。请求体里的
// target_categories 也必须显式带 Copyright,否则作品行拿不到。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plana_app/features/editor/data/artist_oc_library.dart';
import 'package:plana_app/features/editor/data/completion_source.dart';
import 'package:plana_app/features/editor/data/local_tag_db.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_completion.dart';

const _base = 'http://backend.test';

void main() {
  /// 最近一次 /api/tags/search 的请求体(断言 target_categories 用)。
  Map<String, dynamic>? lastSearchBody;

  http.Client makeClient() {
    lastSearchBody = null;
    return MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/api/tags/autocomplete')) {
        return http.Response(
          jsonEncode([
            {'value': 'hatsune_miku', 'post_count': 90000, 'category': 4},
            {'value': 'vocaloid', 'post_count': 300000, 'category': 3},
            {'value': 'blue_hair', 'post_count': 50000, 'category': 0},
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (path.endsWith('/api/tags/search')) {
        lastSearchBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'results': [
              {
                // 上游的 cn_name 是逗号串:中文名 + 出处 + 分类词
                'tag': 'hatsune_miku',
                'cn_name': '初音未来,角色人数,VOCALOID,虚拟歌姬',
                'count': 90000,
                'category': 'Character',
              },
              {
                'tag': 'vocaloid',
                'cn_name': 'VOCALOID,音乐软件',
                'count': 300000,
                'category': 'Copyright',
              },
              {
                'tag': 'blue_hair',
                'cn_name': '蓝发',
                'count': 50000,
                'category': 'General',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      // 画师库 / wiki:一律空,让它们各自 fail-soft
      return http.Response('{}', 404);
    });
  }

  TagCompletion makeCompletion(http.Client c) => TagCompletion(
    source: CompletionSource.enhanced,
    baseUrl: _base,
    localDb: LocalTagDb(),
    artistOcLib: ArtistOcLibrary(_base, null, c),
    client: c,
  );

  test('autocomplete:category 4 进角色桶、3 进作品桶,其余留在标签桶', () async {
    final res = await makeCompletion(makeClient()).query('hatsune');
    expect(res.characters.map((s) => s.text), ['hatsune miku']);
    expect(res.works.map((s) => s.text), ['vocaloid']);
    expect(res.tags.map((s) => s.text), ['blue hair']);
    expect(res.characters.single.kind, SuggestionKind.character);
  });

  test('语义搜索:Character / Copyright 同样各自归组', () async {
    final res = await makeCompletion(makeClient()).query('初音'); // 中文 → 语义搜索
    expect(res.characters.map((s) => s.text), ['hatsune miku']);
    expect(res.works.map((s) => s.text), ['vocaloid']);
    expect(res.tags.map((s) => s.text), contains('blue hair'));
  });

  test('cn_name 只取第一段当译名,后面几段不当出处用', () async {
    final res = await makeCompletion(makeClient()).query('初音');
    final miku = res.characters.single;
    // 不是整条 '初音未来,角色人数,VOCALOID,虚拟歌姬'
    expect(miku.trans, '初音未来');
    // 第二段是「角色人数」这种分类词,不是出处 —— 猜了只会显示错的
    expect(miku.source, isNull);
  });

  test('语义搜索请求显式带 target_categories(含 Copyright)', () async {
    final c = makeClient();
    await makeCompletion(c).query('初音');
    expect(lastSearchBody?['target_categories'], [
      'General',
      'Character',
      'Copyright',
    ]);
  });
}
