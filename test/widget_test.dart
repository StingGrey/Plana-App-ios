import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/main.dart';

/// 测试环境无 Keystore,固定「已选直连」跳过引导页,直接冒烟创作页。
class _TokenMode extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

void main() {
  testWidgets('创作页冒烟:核心区块可见', (WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        authModeProvider.overrideWith(_TokenMode.new),
      ],
      child: const PlanaApp(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('提示词'), findsOneWidget);
    expect(find.text('角色'), findsOneWidget);
    expect(find.text('生成'), findsWidgets);
    expect(find.text('创作'), findsOneWidget);

    // 放行工作台持久化的 800ms 防抖 Timer,避免拆树时报 pending timer
    await tester.pump(const Duration(milliseconds: 900));
  });
}
