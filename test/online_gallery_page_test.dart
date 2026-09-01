import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_page.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';

class _StubGalleryService extends OnlineGalleryService {
  _StubGalleryService(this.detailItem);

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
      OnlineGalleryDetail(item: detailItem);
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
}
