import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/generate/generate_state.dart';

void main() {
  testWidgets('点击图库种子会同步到生成参数', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(AppStores.ephemeral())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: ResultChrome(
              result: ResultImage(
                id: 'seed-test',
                width: 832,
                height: 1216,
                seed: 2731321199,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('2731321199'));
    await tester.pump();

    expect(container.read(generateProvider).params.seed, '2731321199');

    // 放行顶部提示与工作台持久化防抖计时器。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
