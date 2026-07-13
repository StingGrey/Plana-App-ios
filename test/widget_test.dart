import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/main.dart';

void main() {
  testWidgets('创作页冒烟:核心区块可见', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PlanaApp()));
    await tester.pumpAndSettle();

    expect(find.text('提示词'), findsOneWidget);
    expect(find.text('角色'), findsOneWidget);
    expect(find.text('生成'), findsWidgets);
    expect(find.text('创作'), findsOneWidget);
  });
}
