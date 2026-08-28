import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/gen_settings.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';
import 'package:plana_app/main.dart';

/// 测试环境无 Keystore,固定「已选直连」跳过引导页,直接冒烟创作页。
class _TokenMode extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

/// 同理跳过首启的通知说明页(notifyPrimed 已过)。
class _PrimedSettings extends GenSettingsNotifier {
  @override
  Future<GenSettings> build() async => const GenSettings(notifyPrimed: true);
}

void main() {
  testWidgets('正负面提示词可分别折叠与展开', (tester) async {
    final stores = AppStores.ephemeral();
    const positive =
        'first prompt line, second prompt line, final positive tag';
    const negative = 'lowres, bad anatomy, text, watermark, final negative tag';
    stores.workspace.initial = GenerateState.initial().copyWith(
      prompt: positive,
      negativePrompt: negative,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStoresProvider.overrideWithValue(stores)],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: PromptCard())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final positiveText = tester.widget<Text>(find.text(positive));
    final negativeText = tester.widget<Text>(find.text(negative));
    expect(positiveText.maxLines, isNull);
    expect(positiveText.overflow, isNull);
    expect(negativeText.maxLines, isNull);
    expect(negativeText.overflow, isNull);

    final promptCard = find.byType(PromptCard);
    final positiveOnlyHeight = tester.getSize(promptCard).height;
    expect(find.byTooltip('收起正面提示词'), findsOneWidget);
    expect(find.byTooltip('展开负面提示词'), findsOneWidget);

    await tester.tap(find.byTooltip('收起正面提示词'));
    await tester.pumpAndSettle();
    final bothCollapsedHeight = tester.getSize(promptCard).height;
    expect(bothCollapsedHeight, lessThan(positiveOnlyHeight));
    expect(find.byTooltip('展开正面提示词'), findsOneWidget);
    expect(find.byTooltip('展开负面提示词'), findsOneWidget);

    await tester.tap(find.byTooltip('展开负面提示词'));
    await tester.pumpAndSettle();
    final negativeOnlyHeight = tester.getSize(promptCard).height;
    expect(negativeOnlyHeight, greaterThan(bothCollapsedHeight));
    expect(find.byTooltip('展开正面提示词'), findsOneWidget);
    expect(find.byTooltip('收起负面提示词'), findsOneWidget);

    await tester.tap(find.byTooltip('展开正面提示词'));
    await tester.pumpAndSettle();
    expect(tester.getSize(promptCard).height, greaterThan(negativeOnlyHeight));
    expect(find.byTooltip('收起正面提示词'), findsOneWidget);
    expect(find.byTooltip('收起负面提示词'), findsOneWidget);

    await tester.tap(find.byTooltip('收起负面提示词'));
    await tester.pumpAndSettle();
    expect(tester.getSize(promptCard).height, positiveOnlyHeight);

    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('创作页冒烟:核心区块可见', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          authModeProvider.overrideWith(_TokenMode.new),
          genSettingsProvider.overrideWith(_PrimedSettings.new),
        ],
        child: const PlanaApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('提示词'), findsOneWidget);
    expect(find.text('角色'), findsOneWidget);
    expect(find.text('生成'), findsWidgets);
    expect(find.text('创作'), findsOneWidget);

    final promptCard = find.byType(PromptCard);
    final expandedHeight = tester.getSize(promptCard).height;
    expect(find.text('点击编辑正面提示词…'), findsOneWidget);
    expect(find.byTooltip('展开负面提示词'), findsOneWidget);
    await tester.tap(find.byTooltip('收起正面提示词'));
    await tester.pumpAndSettle();
    expect(tester.getSize(promptCard).height, lessThan(expandedHeight));
    expect(find.byTooltip('展开正面提示词'), findsOneWidget);
    expect(find.byTooltip('展开负面提示词'), findsOneWidget);
    await tester.tap(find.byTooltip('展开正面提示词'));
    await tester.pumpAndSettle();
    expect(tester.getSize(promptCard).height, expandedHeight);

    // 放行工作台持久化的 800ms 防抖 Timer,避免拆树时报 pending timer
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('横屏平板:左设置 + 中图库 + 导航轨同时可见', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStoresProvider.overrideWithValue(AppStores.ephemeral()),
          authModeProvider.overrideWith(_TokenMode.new),
          genSettingsProvider.overrideWith(_PrimedSettings.new),
        ],
        child: const PlanaApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('提示词'), findsOneWidget);
    expect(find.text('还没有作品'), findsWidgets);
    expect(find.text('历史记录  0'), findsOneWidget);

    final settingsPanel = find.byKey(const ValueKey('tablet-settings-panel'));
    final initialSettingsWidth = tester.getSize(settingsPanel).width;
    await tester.drag(
      find.byKey(const ValueKey('tablet-settings-resizer')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(settingsPanel).width,
      greaterThan(initialSettingsWidth),
    );

    await tester.tap(find.byTooltip('收起历史记录'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开历史记录'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 900));
  });
}
