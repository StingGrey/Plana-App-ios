import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_page.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';
import 'package:plana_app/features/online_gallery/online_gallery_source_lookup.dart';

String? _term(String url) => gallerySourceLookup(url)?.term;

/// 只记下每次 fetch 用的来源 / 页签 / 查询,不发网络请求。
class _RecordingService extends OnlineGalleryService {
  final calls = <(OnlineGallerySource, OnlineGalleryFeed, String)>[];

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
    calls.add((source, feed, query));
    return const OnlineGalleryPageResult(items: [], hasMore: false);
  }

  @override
  Future<OnlineGalleryDetail> detail(OnlineGalleryItem item) async =>
      OnlineGalleryDetail(item: item, images: const []);
}

void main() {
  group('出处链接 → Danbooru 搜索词', () {
    test('Pixiv:作品页、多语言前缀、旧版链接、原图地址都按作品 ID 查', () {
      for (final url in [
        'https://www.pixiv.net/artworks/122778833',
        'https://www.pixiv.net/en/artworks/122778833',
        'pixiv.net/artworks/122778833',
        'https://www.pixiv.net/member_illust.php?mode=medium&illust_id=122778833',
        'https://i.pximg.net/img-original/img/2024/09/26/08/05/13/122778833_p0.png',
        'https://i.pximg.net/img-zip-ugoira/img/2024/09/26/08/05/13/122778833_ugoira1920x1080.zip?original',
        'https://www.phixiv.net/artworks/122778833',
      ]) {
        expect(_term(url), 'pixiv:122778833', reason: url);
      }
      expect(
        gallerySourceLookup(
          'https://i.pximg.net/img-master/a/1_p0.jpg',
        )?.pageUrl,
        'https://www.pixiv.net/artworks/1',
      );
    });

    test('X:twitter.com / x.com / 修图站 / 带跟踪参数都按推文 ID 通配', () {
      for (final url in [
        'https://x.com/pita_39/status/1847774736501338594',
        'https://twitter.com/pita_39/status/1847774736501338594?s=20&t=abc',
        'https://mobile.twitter.com/pita_39/status/1847774736501338594',
        'https://x.com/i/web/status/1847774736501338594',
        'https://fxtwitter.com/pita_39/status/1847774736501338594/photo/1',
        'x.com/pita_39/status/1847774736501338594',
      ]) {
        expect(_term(url), 'source:*status/1847774736501338594*', reason: url);
      }
      expect(
        _term('https://pbs.twimg.com/media/CZY2VeDUMAACGPN.jpg:orig'),
        'source:*twimg.com/media/CZY2VeDUMAACGPN*',
      );
    });

    test('其余按 ID 认的站:库里写法和粘贴写法不一样也能对上', () {
      expect(
        _term(
          'https://bsky.app/profile/someone.bsky.social/post/3n37rp73b5k26',
        ),
        'source:*bsky.app/profile/*/post/3n37rp73b5k26*',
      );
      expect(
        _term('https://www.fanbox.cc/@muk-monsieur/posts/12978885'),
        'source:*fanbox.cc*/posts/12978885*',
      );
      expect(
        _term('https://muk-monsieur.fanbox.cc/posts/12978885'),
        'source:*fanbox.cc*/posts/12978885*',
      );
      expect(
        _term('https://www.artstation.com/artwork/elLLaP'),
        'source:*artstation.com*/elLLaP*',
      );
      expect(
        _term('https://www.tumblr.com/tonteki555/815577964634898432/slug'),
        'source:*tumblr.com*815577964634898432*',
      );
      expect(
        _term('https://t.bilibili.com/1275027613815930885'),
        'source:*bilibili.com*1275027613815930885*',
      );
    });

    test('Danbooru 帖子链接直接按 ID;它的搜索页不算出处', () {
      expect(_term('https://danbooru.donmai.us/posts/12632983'), 'id:12632983');
      expect(
        _term('https://safebooru.donmai.us/posts/12632983?q=a'),
        'id:12632983',
      );
      expect(
        gallerySourceLookup('https://danbooru.donmai.us/posts?tags=solo'),
        isNull,
      );
    });

    test('认不出的站去协议和 www、去跟踪参数后整段通配', () {
      expect(
        _term(
          'https://www.deviantart.com/taruyamame/art/Exeggutor-1237235477/',
        ),
        'source:*deviantart.com/taruyamame/art/Exeggutor-1237235477*',
      );
      expect(
        _term('https://nijie.info/view.php?id=776219&utm_source=x'),
        'source:*nijie.info/view.php?id=776219*',
      );
      // 只有域名没有路径,查了也是全站,不当出处
      expect(gallerySourceLookup('https://misskey.io/'), isNull);
    });

    test('普通标签不会被当成链接', () {
      for (final tag in [
        'k/da_(league_of_legends)',
        'ranma_1/2',
        'blue_archive',
        '1.5/10',
        'source:*pixiv*',
        'pixiv:123',
        '',
      ]) {
        expect(gallerySourceLookup(tag), isNull, reason: tag);
      }
    });

    test('查询里的链接换成搜索词,其余标签原样留着', () {
      expect(
        rewriteGallerySourceQuery(
          ' solo  https://www.pixiv.net/artworks/122778833 ',
        ),
        'solo pixiv:122778833',
      );
      expect(
        rewriteGallerySourceQuery('blue_archive -ai_generated'),
        'blue_archive -ai_generated',
      );
      expect(gallerySourceLookupIn('solo https://x.com/a/status/1')?.site, 'X');
    });
  });

  group('Danbooru 搜索', () {
    Future<(Uri, OnlineGalleryPageResult)> search(
      String query,
      String body,
    ) async {
      late Uri seen;
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          seen = req.url;
          return http.Response(body, 200);
        }),
      );
      addTearDown(service.dispose);
      final result = await service.fetch(
        OnlineGallerySource.danbooru,
        feed: OnlineGalleryFeed.search,
        query: query,
        page: 1,
        ratings: const {'g', 's', 'q', 'e'},
        blacklist: const {},
      );
      return (seen, result);
    }

    const post =
        '[{"id":12632983,"rating":"g","tag_string":"1girl solo",'
        '"large_file_url":"https://cdn.donmai.us/a.jpg",'
        '"source":"https://i.pximg.net/img-original/img/x/122778833_p0.png"}]';

    test('粘贴 Pixiv 作品页:请求换成 pixiv:ID,结果不被本地按字面筛掉', () async {
      final (url, result) = await search(
        'https://www.pixiv.net/artworks/122778833',
        post,
      );
      expect(url.queryParameters['tags'], 'pixiv:122778833');
      expect(result.items.single.id, '12632983');
    });

    test('排除标签 / 元标签的结果不再被本地二次过滤吞掉', () async {
      final (url, result) = await search('solo -ai_generated', post);
      expect(url.queryParameters['tags'], 'solo -ai_generated');
      expect(result.items, hasLength(1));
    });
  });

  group('反查入口', () {
    ProviderContainer container(_RecordingService service) {
      final c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          onlineGalleryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('排行页粘贴出处链接自动切回搜索;普通标签留在排行', () async {
      final service = _RecordingService();
      final c = container(service);
      final n = c.read(onlineGalleryProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      n.setFeed(OnlineGalleryFeed.ranking);
      n.setQuery('blue_archive');
      expect(c.read(onlineGalleryProvider).feed, OnlineGalleryFeed.ranking);
      n.setQuery('https://x.com/a/status/1');
      expect(c.read(onlineGalleryProvider).feed, OnlineGalleryFeed.search);
    });

    test('从 Gelbooru 反查:切到 Danbooru 搜索页并带上链接', () async {
      final service = _RecordingService();
      final c = container(service);
      final n = c.read(onlineGalleryProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      n.setSource(OnlineGallerySource.gelbooru);
      n.lookupSource('https://www.pixiv.net/artworks/1');
      await Future<void>.delayed(Duration.zero);
      final state = c.read(onlineGalleryProvider);
      expect(state.source, OnlineGallerySource.danbooru);
      expect(state.feed, OnlineGalleryFeed.search);
      expect(service.calls.last, (
        OnlineGallerySource.danbooru,
        OnlineGalleryFeed.search,
        'https://www.pixiv.net/artworks/1',
      ));
    });
  });

  group('详情页链接', () {
    Future<void> pumpDetail(
      WidgetTester tester,
      OnlineGalleryItem item,
      _RecordingService service,
      ProviderContainer container,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OnlineGalleryDetailPage(item: item),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    ProviderContainer container(_RecordingService service) {
      final c = ProviderContainer(
        overrides: [
          tagTranslationServiceProvider.overrideWith((ref) {
            final s = TagTranslationService(enabled: false, baseUrl: '');
            ref.onDispose(s.dispose);
            return s;
          }),
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          onlineGalleryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    testWidgets('Danbooru 帖子:帖子链接 + Pixiv 出处换成作品页,不再显示成「简介」', (tester) async {
      const item = OnlineGalleryItem(
        id: '12632983',
        source: OnlineGallerySource.danbooru,
        previewUrl: '',
        imageUrl: '',
        description: 'https://i.pximg.net/img-original/img/x/122778833_p0.png',
      );
      final service = _RecordingService();
      await pumpDetail(tester, item, service, container(service));

      expect(find.text('链接'), findsOneWidget);
      expect(find.text('简介'), findsNothing);
      expect(find.text('danbooru.donmai.us/posts/12632983'), findsOneWidget);
      expect(find.text('pixiv.net/artworks/122778833'), findsOneWidget);
      expect(find.text('在 Danbooru 按出处查找'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Gelbooru 帖子:点「在 Danbooru 按出处查找」切过去并返回列表', (tester) async {
      const item = OnlineGalleryItem(
        id: '42',
        source: OnlineGallerySource.gelbooru,
        previewUrl: '',
        imageUrl: '',
        description: 'https://twitter.com/a/status/1847774736501338594',
      );
      final service = _RecordingService();
      final c = container(service);
      c
          .read(onlineGalleryProvider.notifier)
          .setSource(OnlineGallerySource.gelbooru);
      await pumpDetail(tester, item, service, c);

      expect(
        find.text('gelbooru.com/index.php?page=post&s=view&id=42'),
        findsOneWidget,
      );
      expect(find.text('x.com/i/status/1847774736501338594'), findsOneWidget);
      await tester.tap(find.text('在 Danbooru 按出处查找'));
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      final state = c.read(onlineGalleryProvider);
      expect(state.source, OnlineGallerySource.danbooru);
      expect(state.query, 'https://x.com/i/status/1847774736501338594');
    });
  });
}
