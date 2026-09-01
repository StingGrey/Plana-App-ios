import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/result_detail_page.dart';
import 'package:plana_app/features/generate/models.dart';

const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x62,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('平板详情页把图片和参数放在左右两栏', (tester) async {
    final stores = AppStores.ephemeral();
    final snapshot = GenerateState.initial().copyWith(
      prompt: '1girl, blue eyes, detailed background',
      negativePrompt: 'lowres',
    );
    final result = ResultImage(
      id: 'tablet-detail-test',
      width: 832,
      height: 1216,
      seed: 42,
      bytes: Uint8List.fromList(_png),
      input: snapshot,
    );

    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      stores.flushNow();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStoresProvider.overrideWithValue(stores)],
        child: MaterialApp(home: ResultDetailPage(result: result)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tablet-result-detail')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tablet-result-detail-parameters')),
      findsOneWidget,
    );
    expect(find.text('参数与提示词'), findsOneWidget);
    expect(find.text(snapshot.prompt), findsOneWidget);

    final panes = tester.getRect(
      find.byKey(const ValueKey('tablet-result-detail')),
    );
    final params = tester.getRect(
      find.byKey(const ValueKey('tablet-result-detail-parameters')),
    );
    expect(params.left, greaterThan(panes.left));
    expect(params.width, lessThan(panes.width));
  });
}
