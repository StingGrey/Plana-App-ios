import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/data/completion_source.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/prompt_blacklist.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/editor/widgets/rich_tag_controller.dart';

void main() {
  group('提示词黑名单规范化', () {
    test('空格、下划线、大小写视为同一条并去重', () {
      expect(
        parsePromptBlacklistText(
          'Huge_Penis\nhuge   penis，watermark,  WATERMARK ',
        ),
        ['huge penis', 'watermark'],
      );
      expect(
        isPromptTagBlacklisted('HUGE__PENIS', const ['huge penis']),
        isTrue,
      );
    });

    test('设置 JSON 往返并兼容字符串形态', () {
      final settings = const EditorSettings().copyWith(
        promptBlacklist: ['Huge_Penis', 'watermark'],
        promptBlacklistMode: PromptBlacklistMode.highlight,
      );
      expect(settings.promptBlacklist, ['huge penis', 'watermark']);
      expect(settings.promptBlacklistMode, PromptBlacklistMode.highlight);
      expect(EditorSettings.fromJson(settings.toJson()), settings);
      expect(
        EditorSettings.fromJson({
          'promptBlacklist': 'huge_penis\nwatermark',
        }).promptBlacklist,
        ['huge penis', 'watermark'],
      );
      expect(
        EditorSettings.fromJson(const {}).promptBlacklistMode,
        PromptBlacklistMode.remove,
      );
    });

    test('正则保留原样，非法正则不会崩溃', () {
      expect(parsePromptBlacklistText('/huge penis/\n/[/\nhuge_penis'), [
        '/huge penis/',
        '/[/',
        'huge penis',
      ]);
      expect(isPromptTagBlacklisted('anything', const ['/[/']), isFalse);
    });
  });

  group('提示词黑名单过滤', () {
    test('完整 tag 命中；空格与下划线等价', () {
      final result = filterPromptBlacklist(
        '1girl, huge_penis, smile, HUGE   PENIS, watermark',
        const ['huge penis'],
      );
      expect(result.text, '1girl, smile, watermark');
      expect(result.removedCount, 2);
    });

    test('只删完整 tag，不误删包含同一前缀的更长 tag', () {
      final result = filterPromptBlacklist(
        'girl, girl on top, schoolgirl',
        const ['girl'],
      );
      expect(result.text, 'girl on top, schoolgirl');
      expect(result.removedCount, 1);
    });

    test('正则命中组合词时删除逗号之间的整枚 tag', () {
      final result = filterPromptBlacklist(
        'safe, **penis, penis **, huge penis focus, smile',
        const ['/penis/'],
      );
      expect(result.text, 'safe, smile');
      expect(result.removedCount, 3);
    });

    test('正则忽略大小写，并能用空格匹配下划线', () {
      expect(
        isPromptTagBlacklisted('HUGE_PENIS', const ['/huge penis/']),
        isTrue,
      );
      expect(isPromptTagBlacklisted('PeNiS FoCuS', const ['/penis/']), isTrue);
    });

    test('普通规则仍是完整 tag 匹配', () {
      expect(
        isPromptTagBlacklisted('huge penis focus', const ['penis']),
        isFalse,
      );
      expect(isPromptTagBlacklisted('penis', const ['penis']), isTrue);
    });

    test('带权重/禁用语法的 tag 同样删除', () {
      final result = filterPromptBlacklist(
        '{huge_penis}, 1.2::smile::, ~watermark~',
        const ['huge penis', 'watermark'],
      );
      expect(result.text, '1.2::smile::');
      expect(result.removedCount, 2);
    });

    test('逐字输入只删已有分隔符的完整 tag', () {
      final typing = filterPromptBlacklist('huge penis', const [
        'huge penis',
      ], completedOnly: true);
      expect(typing.changed, isFalse);

      final committed = filterPromptBlacklist('huge penis, smile', const [
        'huge penis',
      ], completedOnly: true);
      expect(committed.text, 'smile');
    });

    test('删除后同步修正光标', () {
      const source = '1girl, huge_penis, smile';
      final result = filterPromptBlacklist(source, const [
        'huge penis',
      ], cursor: source.length);
      expect(result.text, '1girl, smile');
      expect(result.cursor, result.text.length);
    });
  });

  testWidgets('文本编辑器粘贴 tag 列表后自动移除黑名单项', (tester) async {
    final stores = AppStores.ephemeral();
    final container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        effectiveCompletionSourceProvider.overrideWithValue(
          CompletionSource.danbooru,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(editorSettingsProvider.future);
    // patch 先同步改 provider、随后才异步落盘。组件测试的 fake async zone
    // 不等待真实文件 I/O;这里关心的是即时状态,持久化回环已有纯单测覆盖。
    unawaited(
      container
          .read(editorSettingsProvider.notifier)
          .patch(
            (settings) => settings.copyWith(
              enableCompletion: false,
              promptBlacklist: ['huge penis'],
            ),
          ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: EditorPage(positive: true)),
      ),
    );
    await tester.pump();
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    const pasted = '1girl, huge_penis, smile';
    field.controller!.value = const TextEditingValue(
      text: pasted,
      selection: TextSelection.collapsed(offset: pasted.length),
    );
    await tester.pump();

    expect(field.controller!.text, '1girl, smile');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('标红模式保留命中项，并可一键删除整枚标签', (tester) async {
    final stores = AppStores.ephemeral();
    final container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        effectiveCompletionSourceProvider.overrideWithValue(
          CompletionSource.danbooru,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(editorSettingsProvider.future);
    unawaited(
      container
          .read(editorSettingsProvider.notifier)
          .patch(
            (settings) => settings.copyWith(
              enableCompletion: false,
              promptBlacklist: ['/penis/'],
              promptBlacklistMode: PromptBlacklistMode.highlight,
            ),
          ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: EditorPage(positive: true)),
      ),
    );
    await tester.pump();
    await tester.pump();

    final fieldFinder = find.byType(TextField).first;
    final field = tester.widget<TextField>(fieldFinder);
    const pasted = 'safe, **penis focus, smile';
    field.controller!.value = const TextEditingValue(
      text: pasted,
      selection: TextSelection.collapsed(offset: pasted.length),
    );
    await tester.pump();

    expect(field.controller!.text, pasted);
    expect(find.text('发现 1 个黑名单标签'), findsOneWidget);
    expect(find.text('全部删除'), findsOneWidget);

    final controller = field.controller! as RichTagController;
    final context = tester.element(fieldFinder);
    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(),
      withComposing: false,
    );
    final error = Theme.of(context).colorScheme.error;
    expect(
      span.children!.whereType<TextSpan>().any(
        (child) =>
            child.text?.contains('**penis focus') == true &&
            child.style?.color == error,
      ),
      isTrue,
    );

    await tester.tap(find.text('全部删除'));
    await tester.pump();
    expect(field.controller!.text, 'safe, smile');
    expect(find.text('全部删除'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('芯片模式将正则命中的标签标红', (tester) async {
    final controller = RichTagController(text: 'safe, huge_penis focus');
    final input = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(input.dispose);
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChipFlowView(
            controller: controller,
            foldBodies: const {},
            selection: const {},
            onSelectionChanged: (_) {},
            onMove: (_) {},
            input: input,
            inputFocus: focus,
            onInputChanged: (_) {},
            onInputSubmitted: (_) {},
            translating: (_) => false,
            showTrans: false,
            promptBlacklist: const ['/penis/'],
          ),
        ),
      ),
    );
    await tester.pump();

    final context = tester.element(find.text('huge_penis focus'));
    final label = tester.widget<Text>(find.text('huge_penis focus'));
    expect(label.style?.color, Theme.of(context).colorScheme.error);
  });
}
