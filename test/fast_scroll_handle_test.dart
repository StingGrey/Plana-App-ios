import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/fast_scroll_handle.dart';

Widget _app(ScrollController ctrl, int count) => MaterialApp(
  home: Scaffold(
    body: FastScrollHandle(
      child: ListView.builder(
        controller: ctrl,
        itemCount: count,
        itemExtent: 50,
        itemBuilder: (_, i) => Text('$i'),
      ),
    ),
  ),
);

Finder get _thumb => find.descendant(
  of: find.byType(FastScrollHandle),
  matching: find.byType(AnimatedContainer),
);

double _opacity(WidgetTester t) => t
    .widget<Opacity>(
      find.ancestor(of: _thumb, matching: find.byType(Opacity)).first,
    )
    .opacity;

void main() {
  testWidgets('长列表滚动时浮出,停下后收回', (t) async {
    final ctrl = ScrollController();
    await t.pumpWidget(_app(ctrl, 200));
    expect(_opacity(t), 0);

    await t.drag(find.byType(ListView), const Offset(0, -300));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(_opacity(t), 1);

    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(_opacity(t), 0);
  });

  testWidgets('不到两屏不出现', (t) async {
    final ctrl = ScrollController();
    await t.pumpWidget(_app(ctrl, 20));
    await t.drag(find.byType(ListView), const Offset(0, -200));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(_opacity(t), 0);
  });

  testWidgets('按住把手拖到底,列表跟到底', (t) async {
    final ctrl = ScrollController();
    await t.pumpWidget(_app(ctrl, 200));
    await t.drag(find.byType(ListView), const Offset(0, -100));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    await t.drag(_thumb, const Offset(0, 2000));
    await t.pump();
    expect(ctrl.offset, ctrl.position.maxScrollExtent);

    await t.drag(_thumb, const Offset(0, -2000));
    await t.pump();
    expect(ctrl.offset, 0);
  });
}
