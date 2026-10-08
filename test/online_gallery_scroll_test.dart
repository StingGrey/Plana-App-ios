import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_page.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';

class _Service extends OnlineGalleryService {
  int requests = 0;
  @override
  Future<OnlineGalleryDetail> detail(OnlineGalleryItem item) async =>
      OnlineGalleryDetail(item: item);

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
    requests++;
    return OnlineGalleryPageResult(
      items: List.generate(
        60,
        (i) => OnlineGalleryItem(
          id: '$i',
          source: source,
          previewUrl: '',
          imageUrl: '',
          width: 800,
          height: 1200,
        ),
      ),
      hasMore: false,
    );
  }
}

void main() {
  testWidgets(
    'reopening gallery restores scroll without refetch; refresh starts at top',
    (tester) async {
      final service = _Service();
      addTearDown(service.dispose);
      final container = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          onlineGalleryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigator,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const OnlineGalleryPage(),
                    ),
                  ),
                  child: const Text('open gallery'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open gallery'));
      await tester.pumpAndSettle();
      final list = find.byType(SingleChildScrollView);
      await tester.drag(list, const Offset(0, -1700));
      await tester.pumpAndSettle();
      final before = tester
          .widget<SingleChildScrollView>(list)
          .controller!
          .offset;
      expect(before, greaterThan(1000));
      container
          .read(generateProvider.notifier)
          .setPrompts(positive: 'old', negative: 'keep negative');
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const OnlineGalleryDetailPage(
            item: OnlineGalleryItem(
              id: 'import',
              source: OnlineGallerySource.danbooru,
              previewUrl: '',
              imageUrl: '',
              tags: ['1girl'],
              tagCategories: {'1girl': OnlineGalleryTagCategory.general},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用提示词'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入生图'));
      await tester.pumpAndSettle();
      expect(find.byType(OnlineGalleryPage), findsNothing);
      expect(container.read(generateProvider).prompt, '1girl');
      expect(container.read(generateProvider).negativePrompt, 'keep negative');
      await tester.tap(find.text('open gallery'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SingleChildScrollView>(list).controller!.offset,
        closeTo(before, 1),
      );
      expect(service.requests, 1);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(tester.widget<SingleChildScrollView>(list).controller!.offset, 0);
      expect(service.requests, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
