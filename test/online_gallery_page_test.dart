import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/data/suggestions.dart'
    show cacheTagMeta;
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_page.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';

class _StubGalleryService extends OnlineGalleryService {
  _StubGalleryService(this.detailItem, {this.images = const []});
  final List<OnlineGalleryItem> images;

  final OnlineGalleryItem detailItem;

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
  }) async => const OnlineGalleryPageResult(items: [], hasMore: false);

  @override
  Future<OnlineGalleryDetail> detail(OnlineGalleryItem item) async =>
      OnlineGalleryDetail(item: detailItem, images: images);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('详情页操作栏固定在底部且图片区域不会被挤没', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    const item = OnlineGalleryItem(
      id: 'detail-layout-test',
      source: OnlineGallerySource.danbooru,
      previewUrl: '',
      imageUrl: '',
      width: 832,
      height: 1216,
    );
    final service = _StubGalleryService(item);
    addTearDown(service.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tagTranslationServiceProvider.overrideWith((ref) {
            final service = TagTranslationService(enabled: false, baseUrl: '');
            ref.onDispose(service.dispose);
            return service;
          }),
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          onlineGalleryServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(home: OnlineGalleryDetailPage(item: item)),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.getRect(
      find.byKey(const ValueKey('online-gallery-detail-image')),
    );
    final actions = tester.getRect(
      find.byKey(const ValueKey('online-gallery-detail-actions')),
    );

    expect(image.height, greaterThan(100));
    expect(actions.top, greaterThan(400));
    expect(actions.bottom, closeTo(768, 1));
  });
  testWidgets('窄屏:标签带中文译名、画师不翻;图不超过六成屏高,操作吸底', (tester) async {
    cacheTagMeta('long_hair', trans: '长发');
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    const item = OnlineGalleryItem(
      id: 'detail-tags-test',
      source: OnlineGallerySource.danbooru,
      previewUrl: '',
      imageUrl: '',
      width: 600,
      height: 1800,
      tags: ['long_hair', 'some_artist'],
      tagCategories: {
        'long_hair': OnlineGalleryTagCategory.general,
        'some_artist': OnlineGalleryTagCategory.artist,
      },
    );
    final service = _StubGalleryService(item);
    addTearDown(service.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tagTranslationServiceProvider.overrideWith((ref) {
            final service = TagTranslationService(enabled: false, baseUrl: '');
            ref.onDispose(service.dispose);
            return service;
          }),
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          onlineGalleryServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(home: OnlineGalleryDetailPage(item: item)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('long hair'), findsOneWidget);
    expect(find.text('长发'), findsOneWidget);
    expect(find.text('some artist'), findsOneWidget);
    final image = tester.getRect(
      find.byKey(const ValueKey('online-gallery-detail-image')),
    );
    expect(image.height, lessThanOrEqualTo(844 * .6 + 1));
    final actions = tester.getRect(
      find.byKey(const ValueKey('online-gallery-detail-actions')),
    );
    expect(actions.bottom, closeTo(844, 1));
    expect(find.text('使用提示词'), findsOneWidget);
    expect(find.text('保存本地'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI TAG 切换图片后导入对应提示词而非作品标签', (tester) async {
    const first = OnlineGalleryItem(
      id: 'multi',
      source: OnlineGallerySource.aiTag,
      previewUrl: '',
      imageUrl: '',
      platform: 'NAI',
      prompt: 'first prompt',
      tags: ['publication tag'],
    );
    final second = first.copyWith(
      prompt: 'second prompt',
      negativePrompt: 'lowres',
      platform: 'SD',
    );
    final service = _StubGalleryService(first, images: [first, second]);
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
        child: const MaterialApp(home: OnlineGalleryDetailPage(item: first)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('图片 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用提示词'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == 'second prompt',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('导入生图'));
    await tester.pumpAndSettle();
    expect(container.read(generateProvider).prompt, 'second prompt');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });
}
