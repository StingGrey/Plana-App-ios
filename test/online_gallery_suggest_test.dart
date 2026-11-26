// 在线画廊搜索框的标签联想:光标所在的词怎么取、怎么换回去;三个来源的
// 联想接口怎么解析,站点挂了退回离线词库;界面上打字 → 下拉 → 点一条就搜。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/data/tag_index.dart' show TagHit;
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_page.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';
import 'package:plana_app/features/online_gallery/online_gallery_tag_chips.dart';

TextEditingValue _at(String text, [int? cursor]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: cursor ?? text.length),
);

class _Service extends OnlineGalleryService {
  final queries = <String>[];
  final terms = <String>[];

  @override
  Future<OnlineGalleryPageResult> fetch(
    OnlineGallerySource source, {
    required OnlineGalleryFeed feed,
    required String query,
    required int page,
    required Set<String> ratings,
    required Set<String> blacklist,
    String rankingPeriod = 'day',
    int dateDays = 0,
  }) async {
    queries.add(query);
    return const OnlineGalleryPageResult(items: [], hasMore: false);
  }

  @override
  Future<List<GalleryTagSuggestion>> suggestTags(
    OnlineGallerySource source,
    String term, {
    int limit = 10,
  }) async {
    terms.add(term);
    return const [
      GalleryTagSuggestion(
        value: 'shouu-kun',
        label: 'shouu-kun',
        category: OnlineGalleryTagCategory.artist,
        postCount: 395,
      ),
      GalleryTagSuggestion(
        value: 'shouu_ootengu',
        label: 'shouu ootengu',
        category: OnlineGalleryTagCategory.character,
        postCount: 8,
      ),
    ];
  }
}

void main() {
  group('光标所在的词', () {
    test('取最后一个词,换掉后补空格接着输入', () {
      final w = galleryQueryWordAt(_at('1girl shouu'))!;
      expect(w.term, 'shouu');
      expect(galleryQueryReplace(w, 'shouu-kun'), '1girl shouu-kun ');
    });

    test('排除前缀保留;光标在中间的词就换中间那个', () {
      final neg = galleryQueryWordAt(_at('solo -blon'))!;
      expect((neg.prefix, neg.term), ('-', 'blon'));
      expect(galleryQueryReplace(neg, 'blonde_hair'), 'solo -blonde_hair ');

      final mid = galleryQueryWordAt(_at('aaa hats bbb', 7))!;
      expect(mid.term, 'hats');
      expect(galleryQueryReplace(mid, 'hatsune_miku'), 'aaa hatsune_miku bbb');
    });

    test('光标在空白上、只有前缀时不联想', () {
      expect(galleryQueryWordAt(_at('solo ')), isNull);
      expect(galleryQueryWordAt(_at('solo -')), isNull);
      expect(galleryWorthSuggesting('s'), isFalse);
      expect(galleryWorthSuggesting('sh'), isTrue);
      expect(galleryWorthSuggesting('初'), isTrue);
    });

    test('帖子数缩写', () {
      expect(formatTagPostCount(395), '395');
      expect(formatTagPostCount(5960), '6k');
      expect(formatTagPostCount(62379), '62k');
      expect(formatTagPostCount(150055), '150k');
      expect(formatTagPostCount(2254000), '2.3M');
    });
  });

  group('联想接口', () {
    test('Danbooru:类目、帖子数、别名原词,元标签显示全名', () async {
      final seen = <Uri>[];
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          seen.add(req.url);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode([
                {
                  'type': 'tag-word',
                  'label': 'shouu-kun',
                  'value': 'shouu-kun',
                  'category': 1,
                  'post_count': 395,
                },
                {
                  'type': 'tag-other-name',
                  'label': 'hatsune miku',
                  'value': 'hatsune_miku',
                  'category': 4,
                  'post_count': 150055,
                  'antecedent': '初音ミク',
                },
                {
                  'type': 'static',
                  'label': 'general',
                  'value': 'rating:general',
                },
              ]),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(service.dispose);
      final list = await service.suggestTags(
        OnlineGallerySource.safebooru,
        'shouu',
      );
      expect(seen.single.host, 'danbooru.donmai.us');
      expect(seen.single.path, '/autocomplete.json');
      expect(seen.single.queryParameters['search[query]'], 'shouu');
      expect(list.map((s) => s.category), [
        OnlineGalleryTagCategory.artist,
        OnlineGalleryTagCategory.character,
        OnlineGalleryTagCategory.meta,
      ]);
      expect(list[0].postCount, 395);
      expect(list[1].antecedent, '初音ミク');
      expect(list[2].label, 'rating:general');
    });

    test('Gelbooru:类目是字串,帖子数是字串', () async {
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          expect(req.url.host, 'gelbooru.com');
          expect(req.url.queryParameters['page'], 'autocomplete2');
          return http.Response(
            jsonEncode([
              {
                'type': 'tag',
                'label': 'shouu-kun',
                'value': 'shouu-kun',
                'post_count': '396',
                'category': 'artist',
              },
              {
                'type': 'tag',
                'label': 'shouu ootengu',
                'value': 'shouu_ootengu',
                'post_count': '3',
                'category': 'tag',
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      final list = await service.suggestTags(
        OnlineGallerySource.gelbooru,
        'shouu',
      );
      expect(list.map((s) => (s.value, s.category, s.postCount)), [
        ('shouu-kun', OnlineGalleryTagCategory.artist, 396),
        ('shouu_ootengu', OnlineGalleryTagCategory.general, 3),
      ]);
    });

    test('站点挂了退回离线词库,带中文;AI TAG 直接用离线词库', () async {
      var online = 0;
      Future<List<TagHit>> local(String q, {int limit = 15}) async => [
        (tag: 'long_hair', zh: '长发', count: 4350743, category: 0),
      ];
      final service = OnlineGalleryService(
        client: MockClient((_) async {
          online++;
          return http.Response('oops', 500);
        }),
        localTags: local,
      );
      addTearDown(service.dispose);
      final fallback = await service.suggestTags(
        OnlineGallerySource.danbooru,
        'long_h',
      );
      expect(online, 1);
      expect(fallback.single.value, 'long_hair');
      expect(fallback.single.label, 'long hair');
      expect(fallback.single.translation, '长发');
      expect(fallback.single.category, OnlineGalleryTagCategory.general);

      final ai = await service.suggestTags(OnlineGallerySource.aiTag, 'long');
      expect(online, 1);
      expect(ai.single.value, 'long_hair');
    });
  });

  testWidgets('打字出下拉;点一条换掉光标那个词并直接搜', (tester) async {
    final service = _Service();
    addTearDown(service.dispose);
    final container = ProviderContainer(
      overrides: [
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        onlineGalleryServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: OnlineGalleryPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'solo shou');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(service.terms, ['shou']);
    expect(
      find.byKey(const ValueKey('online-gallery-suggestions')),
      findsOneWidget,
    );
    expect(find.text('395'), findsOneWidget);

    service.queries.clear();
    await tester.tap(find.text('8'));
    await tester.pumpAndSettle();
    expect(container.read(onlineGalleryProvider).query, 'solo shouu_ootengu ');
    expect(service.queries, ['solo shouu_ootengu ']);
    expect(
      find.byKey(const ValueKey('online-gallery-suggestions')),
      findsNothing,
    );
    // 打字触发的自动搜索(350ms 防抖)已被选中这一下取消
    await tester.pump(const Duration(seconds: 1));
    expect(service.queries, ['solo shouu_ootengu ']);
  });
}
