import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/ui_prefs.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/gallery/gallery_date_filter.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_grid_sheet.dart';
import 'package:plana_app/features/gallery/widgets/gallery_range_picker.dart';
import 'package:plana_app/features/gallery/widgets/result_thumb.dart';

void main() {
  testWidgets('现有图库按日期筛选后只显示匹配作品，选全部可恢复', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stores = AppStores.ephemeral();
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    final now = DateTime.now();
    final old = DateTime(now.year, now.month, now.day - 2);
    stores.gallery.initialResults = [
      ResultImage(
        id: 'gen2',
        width: 64,
        height: 64,
        seed: 2,
        createdAt: now.millisecondsSinceEpoch,
        bytes: bytes,
      ),
      ResultImage(
        id: 'gen1',
        width: 64,
        height: 64,
        seed: 1,
        createdAt: old.millisecondsSinceEpoch,
        bytes: bytes,
      ),
    ];
    await tester.runAsync(
      () => stores.prefs.write(key: 'hint_grid_longpress', value: '1'),
    );
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showGalleryGrid(context),
                child: const Text('历史'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('全部相册'), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-date-filter')), findsNothing);
    await tester.tap(find.text('全部相册'));
    await tester.pumpAndSettle();
    expect(find.byType(ResultThumb), findsNWidgets(2));
    expect(
      tester
          .widgetList<ResultThumb>(find.byType(ResultThumb))
          .map((thumb) => thumb.result.id),
      ['gen2', 'gen1'],
    );
    expect(find.text('全部相册'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('按时间'), findsOneWidget);
    expect(tester.getTopLeft(find.text('按时间')).dx, closeTo(28, 1));

    await tester.tap(find.byTooltip('回到相册'));
    await tester.pumpAndSettle();
    expect(find.text('全部相册'), findsOneWidget);
    await tester.tap(find.text('全部相册'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('gallery-date-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天').last);
    await tester.pumpAndSettle();
    expect(find.byType(ResultThumb), findsOneWidget);
    expect(
      container.read(uiPrefsProvider).dateFilter.kind,
      GalleryDateKind.today,
    );
    expect(find.text('按时间'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('gallery-date-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.byType(ResultThumb), findsNWidgets(2));
    expect(
      container.read(uiPrefsProvider).dateFilter.kind,
      GalleryDateKind.all,
    );

    await tester.tap(find.byKey(const ValueKey('gallery-date-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日期范围'));
    await tester.pumpAndSettle();
    expect(find.byType(GalleryRangePicker), findsOneWidget);
    await tester.tap(find.text('应用').last);
    await tester.pumpAndSettle();
    expect(find.byType(ResultThumb), findsOneWidget);
    expect(
      container.read(uiPrefsProvider).dateFilter.kind,
      GalleryDateKind.range,
    );

    await tester.tap(find.byKey(const ValueKey('gallery-date-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();
    expect(find.byType(ResultThumb), findsNWidgets(2));
    expect(find.text('日期'), findsOneWidget);
    expect(
      container.read(uiPrefsProvider).dateFilter.kind,
      GalleryDateKind.all,
    );
    await tester.tap(find.byTooltip('回到相册'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('日期筛选保留现有图库的分组设置', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stores = AppStores.ephemeral();
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showGalleryGrid(context),
                child: const Text('历史'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部相册'));
    await tester.pumpAndSettle();
    expect(find.text('按时间'), findsOneWidget);
    await tester.tap(find.text('按时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按画风').last);
    await tester.pumpAndSettle();
    expect(find.text('按画风'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gallery-date-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('近 7 天'));
    await tester.pumpAndSettle();
    expect(find.text('按画风'), findsOneWidget);
    await tester.tap(find.byTooltip('回到相册'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('空图库仍显示全部相册，返回键先回相册首页', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stores = AppStores.ephemeral();
    await tester.runAsync(
      () => stores.prefs.write(key: 'hint_grid_longpress', value: '1'),
    );
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showGalleryGrid(context),
                child: const Text('历史'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('全部相册'), findsOneWidget);
    expect(find.text('0 张'), findsOneWidget);

    await tester.tap(find.text('全部相册'));
    await tester.pumpAndSettle();
    expect(find.text('图库是空的'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('全部相册'), findsOneWidget);
    expect(find.text('图库是空的'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('全部相册'), findsNothing);
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('全部相册'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('相册首页和全部相册各自保持滚动位置，切换时不跳顶', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stores = AppStores.ephemeral();
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    final now = DateTime.now().millisecondsSinceEpoch;
    stores.gallery.initialResults = [
      for (var i = 0; i < 60; i++)
        ResultImage(
          id: 'gen$i',
          width: 64,
          height: 64,
          seed: i,
          createdAt: now - i * 1000,
          bytes: bytes,
        ),
    ];
    await tester.runAsync(
      () => stores.prefs.write(key: 'hint_grid_longpress', value: '1'),
    );
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showGalleryGrid(context),
                child: const Text('历史'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部相册'));
    await tester.pumpAndSettle();

    final inner = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    inner.jumpTo(600);
    await tester.pump();
    expect(inner.offset, closeTo(600, 1));
    final innerOffsets = <double>[];
    inner.addListener(() {
      if (inner.hasClients) innerOffsets.add(inner.offset);
    });

    await tester.tap(find.byTooltip('回到相册'));
    await tester.pumpAndSettle();
    expect(innerOffsets.where((offset) => offset < 50), isEmpty);
    expect(find.text('全部相册'), findsOneWidget);
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .offset,
      0,
    );

    await tester.tap(find.text('全部相册'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .offset,
      closeTo(600, 1),
    );
    await tester.pumpAndSettle();
    final reopened = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    expect(reopened.offset, closeTo(600, 1));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部相册'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .offset,
      closeTo(600, 1),
    );
    await tester.tap(find.byTooltip('回到相册'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉关闭全部相册后重新打开仍停在展开页和原滚动位置', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stores = AppStores.ephemeral();
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    final now = DateTime.now().millisecondsSinceEpoch;
    stores.gallery.initialResults = [
      for (var i = 0; i < 60; i++)
        ResultImage(
          id: 'gen$i',
          width: 64,
          height: 64,
          seed: i,
          createdAt: now - i * 1000,
          bytes: bytes,
        ),
    ];
    await tester.runAsync(
      () => stores.prefs.write(key: 'hint_grid_longpress', value: '1'),
    );
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showGalleryGrid(context),
                child: const Text('历史'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部相册'));
    await tester.pumpAndSettle();
    final photos = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    photos.jumpTo(600);
    await tester.pump();
    expect(photos.offset, closeTo(600, 1));

    await tester.drag(find.text('全部相册'), const Offset(0, 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gallery-date-filter')), findsNothing);
    expect(find.text('历史'), findsOneWidget);

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gallery-date-filter')), findsOneWidget);
    expect(find.byTooltip('回到相册'), findsOneWidget);
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .offset,
      closeTo(600, 1),
    );

    await tester.tap(find.byTooltip('回到相册'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('相册'), const Offset(0, 700));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-date-filter')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
