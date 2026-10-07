// 提示词卡分区行(369dp 宽):一格一行,操作照角色卡。
//
// 容易坏的几处:窄屏一行塞不下(名字签 + 预览 + 计数 + 两颗按钮)直接溢出;
// 删除没给撤销,或撤销没放回原位;主体那行冒出删除钮;点名字没先拿到手势,
// 被外层「点行进编辑器」抢走。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

class _Presets extends PromptPresetsNotifier {
  @override
  Future<PromptPresetsState> build() async =>
      const PromptPresetsState(presets: kDefaultPromptPresets);
}

const _a12 = TagEntry(
  id: 't1',
  category: TagCategory.artist,
  name: 'A12',
  positive: 'artist:wlop, artist:ask, year 2024',
);

Future<GenerateNotifier> _pumpCard(WidgetTester tester) async {
  tester.view.physicalSize = const Size(369 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      appStoresProvider.overrideWithValue(AppStores.ephemeral()),
      promptPresetsProvider.overrideWith(_Presets.new),
    ],
  );
  addTearDown(c.dispose);
  final gen = c.read(generateProvider.notifier);
  gen.setPromptPreset('none'); // 读数里不掺质量词
  gen.setPrompts(
    positive:
        '1girl, solo, silver hair, long hair, blue eyes, white dress, '
        'looking at viewer, smile',
    negative: 'lowres, bad anatomy',
  );
  gen.addEntrySections([_a12]);
  gen.addSection();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: SingleChildScrollView(child: PromptCard())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gen;
}

/// 工作区落盘是 800ms 防抖、提示条 4 秒,收尾前都走完。
Future<void> _settleTimers(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 5));

void main() {
  testWidgets('窄屏一格一行不溢出;画风条目自成一格,主体没有删除钮', (tester) async {
    await _pumpCard(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('画风'), findsOneWidget);
    expect(find.text('主体'), findsOneWidget);
    expect(find.text('分区 1'), findsOneWidget);
    // 画风、分区 1 各一颗;主体没有
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    expect(find.byIcon(Icons.power_settings_new), findsNWidgets(2));
    await _settleTimers(tester);
  });

  testWidgets('删除给撤销,撤销放回原位', (tester) async {
    final gen = await _pumpCard(tester);
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect([for (final s in gen.state.sections) s.name], ['主体', '分区 1']);
    expect(find.text('已删除「画风」'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect([for (final s in gen.state.sections) s.name], ['主体', '画风', '分区 1']);
    await _settleTimers(tester);
  });

  testWidgets('停用后还能再点开;点名字先拿到手势弹改名', (tester) async {
    final gen = await _pumpCard(tester);
    await tester.tap(find.byIcon(Icons.power_settings_new).first);
    await tester.pumpAndSettle();
    expect(gen.state.sections[1].enabled, isFalse); // 主体那行没有开关,第一颗是画风的
    // 停用的那行预览带删除线
    TextDecoration? deco() => tester
        .widget<Text>(find.textContaining('artist:wlop'))
        .style
        ?.decoration;
    expect(deco(), TextDecoration.lineThrough);
    await tester.tap(find.byIcon(Icons.power_settings_new).first);
    await tester.pumpAndSettle();
    expect(gen.state.sections[1].enabled, isTrue);
    expect(deco(), isNot(TextDecoration.lineThrough));

    await tester.tap(find.text('分区 1'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.byType(EditorPage), findsNothing);
    await tester.enterText(find.byType(TextField), ' 场景 ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(gen.state.sections.last.name, '场景');
    await _settleTimers(tester);
  });

  testWidgets('删到只剩主体,卡片回到两行预览', (tester) async {
    final gen = await _pumpCard(tester);
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(gen.state.sections, isEmpty);
    expect(find.text('主体'), findsNothing);
    expect(find.textContaining('1girl, solo'), findsOneWidget);
    await _settleTimers(tester);
  });

  testWidgets('清空连分区一起清掉,撤销整组放回;清完没东西可清就不显示清空', (tester) async {
    final gen = await _pumpCard(tester);
    await tester.tap(find.byTooltip('清空提示词和分区'));
    await tester.pumpAndSettle();
    expect(gen.state.sections, isEmpty);
    expect(gen.state.prompt, isEmpty);
    expect(gen.state.negativePrompt, 'lowres, bad anatomy'); // 负面留着
    expect(find.text('已清空提示词和分区'), findsOneWidget);
    // 主提示词空了、也没分区:清空按钮收起来(提示条上那枚同款图标不算)
    final clearBtn = find.descendant(
      of: find.byType(PromptCard),
      matching: find.byIcon(Icons.delete_sweep_outlined),
    );
    expect(clearBtn, findsNothing);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect([for (final s in gen.state.sections) s.name], ['主体', '画风', '分区 1']);
    expect(gen.state.prompt, startsWith('1girl, solo'));
    expect(clearBtn, findsOneWidget);
    await _settleTimers(tester);
  });
}
