// 三键导航机上应用整体让出系统导航栏(NavBarGuard)。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/nav_bar_guard.dart';

void main() {
  const screen = Size(400, 800);

  /// edge-to-edge 的窗口:底部系统栏高 [bar],键盘已升起 [ime]。
  /// padding 照引擎的算法取 max(0, viewPadding − viewInsets)。
  MediaQueryData media({double bar = 0, double ime = 0}) => MediaQueryData(
    size: screen,
    viewPadding: EdgeInsets.only(top: 24, bottom: bar),
    padding: EdgeInsets.only(top: 24, bottom: math.max(0, bar - ime)),
    viewInsets: EdgeInsets.only(bottom: ime),
    systemGestureInsets: EdgeInsets.only(bottom: bar),
  );

  late MediaQueryData inner;
  late Size area;

  /// 测试窗口也得是 [screen] 这么大:布局约束来自窗口,不来自 MediaQuery。
  void useScreen(WidgetTester tester) {
    tester.view
      ..devicePixelRatio = 3
      ..physicalSize = screen * 3;
    addTearDown(tester.view.reset);
  }

  Widget guarded(MediaQueryData data, {Widget? child}) => MediaQuery(
    data: data,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: NavBarGuard(
        child:
            child ??
            LayoutBuilder(
              builder: (context, c) {
                inner = MediaQuery.of(context);
                area = c.biggest;
                return const SizedBox.expand();
              },
            ),
      ),
    ),
  );

  testWidgets('三键导航:应用区收到导航栏上沿,底部 padding 清零', (tester) async {
    useScreen(tester);
    await tester.pumpWidget(guarded(media(bar: 48)));
    expect(area, const Size(400, 752));
    expect(inner.size, const Size(400, 752));
    expect(inner.padding.bottom, 0);
    expect(inner.viewPadding.bottom, 0);
    expect(inner.systemGestureInsets.bottom, 0);
    expect(inner.padding.top, 24, reason: '顶部不动');
  });

  testWidgets('手势导航:原样画到屏幕底', (tester) async {
    useScreen(tester);
    final data = media(bar: 24);
    await tester.pumpWidget(guarded(data));
    expect(area, screen);
    expect(inner, data);
  });

  testWidgets('键盘升起:让出的高度跟着收到 0,键盘 inset 原样往下传', (tester) async {
    useScreen(tester);
    // 刚升起一截,还在导航栏后面:内容底边(应用区高 − 键盘 inset)仍停在导航栏上沿
    await tester.pumpWidget(guarded(media(bar: 48, ime: 20)));
    expect(inner.viewInsets.bottom, 20);
    expect(area.height - inner.viewInsets.bottom, 800 - 48);

    await tester.pumpWidget(guarded(media(bar: 48, ime: 300)));
    expect(area, screen);
    expect(inner.viewInsets.bottom, 300);
    expect(inner.padding.bottom, 0);
  });

  testWidgets('导航方式来回切,底下的页面状态不丢', (tester) async {
    useScreen(tester);
    const probe = _Probe(key: ValueKey('probe'));
    await tester.pumpWidget(guarded(media(bar: 48), child: probe));
    final before = tester.state(find.byKey(const ValueKey('probe')));
    await tester.pumpWidget(guarded(media(bar: 24), child: probe));
    await tester.pumpWidget(guarded(media(), child: probe));
    await tester.pumpWidget(guarded(media(bar: 48), child: probe));
    expect(tester.state(find.byKey(const ValueKey('probe'))), same(before));
  });

  testWidgets('没自己留底部安全区的弹层,按钮也落在导航栏之上', (tester) async {
    useScreen(tester);
    tester.view
      ..viewPadding = const FakeViewPadding(bottom: 144)
      ..padding = const FakeViewPadding(bottom: 144);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => NavBarGuard(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => const SizedBox(
                  height: 200,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Text('确定'),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('确定')).bottom, lessThanOrEqualTo(800 - 48));
  });
}

class _Probe extends StatefulWidget {
  const _Probe({super.key});

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
