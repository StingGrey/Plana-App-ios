import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/data/completion_source.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/editor/widgets/tag_panel.dart';
import 'package:plana_app/features/editor/widgets/editor_bottom_bar.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';

void main() {
  testWidgets('文本模式保留原生局部选区,不自动扩成整枚提示词', (tester) async {
    final container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        effectiveCompletionSourceProvider.overrideWithValue(
          CompletionSource.danbooru,
        ),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(generateProvider.notifier)
        .setPrompts(positive: 'abcdef, next');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: EditorPage(positive: true)),
      ),
    );
    await tester.pump();
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    final controller = field.controller!;
    expect(controller.text, 'abcdef, next');

    // iOS 输入法在连续退格/撤销自动修正时可能先给出这种临时局部选区。
    // 旧逻辑会同步扩成 [0, 6],第二次退格便把整枚 abcdef 删掉。
    controller.selection = const TextSelection(baseOffset: 5, extentOffset: 6);
    expect(
      controller.selection,
      const TextSelection(baseOffset: 5, extentOffset: 6),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });
  testWidgets('词条面板展开且键盘占位时正负 tab 仍可见可切换', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        effectiveCompletionSourceProvider.overrideWithValue(
          CompletionSource.danbooru,
        ),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(generateProvider.notifier)
        .setPrompts(positive: '1girl, blue_eyes', negative: 'lowres');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
            child: child!,
          ),
          home: const EditorPage(positive: true),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField).first);
    field.controller!.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TagPanel), findsOneWidget);
    final bar = tester.getRect(find.byType(EditorBottomBar));
    expect(bar.bottom, closeTo(400, 1));
    expect(bar.top, greaterThan(0));
    expect(find.text('负面').hitTestable(), findsOneWidget);
    await tester.tap(find.text('负面'));
    await tester.pump();
    expect(container.read(editorProvider).activePositive, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });
}
