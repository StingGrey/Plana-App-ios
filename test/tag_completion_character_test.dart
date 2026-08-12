// 补全里「D 站角色类目的 tag 归角色分组」这条路由。
//
// 两条来源两套 category 写法:autocomplete 给数字(4=character)、语义搜索给
// 字符串('Character')。认错任何一条,角色就会混在几十条普通标签里 —— 那正是
// 加这个分组前的样子。
//
// 服务端 /api/tags/search 的默认类目 2026-08-12 才从 ['General'] 放开到
// ['General','Character'],所以请求里必须显式带上,否则新旧服务端搜出来的
// 东西不一样。这里也把请求体钉住。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plana_app/features/editor/data/artist_oc_library.dart';
import 'package:plana_app/features/editor/data/completion_source.dart';
import 'package:plana_app/features/editor/data/local_tag_db.dart';
import 'package:plana_app/features/editor/data/role_library.dart';
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
                'tag': 'hatsune_miku',
                'cn_name': '初音未来',
                'count': 90000,
                'category': 'Character',
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
      // 角色库 / 画师库 / wiki / AI 推荐:一律空,让它们各自 fail-soft
      return http.Response('{}', 404);
    });
  }

  TagCompletion makeCompletion(http.Client c) => TagCompletion(
    source: CompletionSource.enhanced,
    baseUrl: _base,
    localDb: LocalTagDb(),
    roleLib: RoleLibrary(_base, c),
    artistOcLib: ArtistOcLibrary(_base, null, c),
    client: c,
  );

  test('autocomplete:category 4 进角色桶,其余留在标签桶', () async {
    final res = await makeCompletion(makeClient()).query('hatsune');
    expect(res.characters.map((s) => s.text), ['hatsune miku']);
    expect(res.tags.map((s) => s.text), ['blue hair']);
    expect(res.characters.single.kind, SuggestionKind.character);
  });

  test('语义搜索:category=Character 同样进角色桶,并带上中文名', () async {
    final c = makeClient();
    final res = await makeCompletion(c).query('初音'); // 中文 → 走语义搜索
    expect(res.characters.map((s) => s.text), ['hatsune miku']);
    expect(res.characters.single.trans, '初音未来');
    expect(res.tags.map((s) => s.text), contains('blue hair'));
  });

  test('语义搜索请求显式带 target_categories', () async {
    final c = makeClient();
    await makeCompletion(c).query('初音');
    expect(lastSearchBody?['target_categories'], ['General', 'Character']);
  });
}
