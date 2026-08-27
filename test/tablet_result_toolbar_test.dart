import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';

void main() {
  testWidgets('平板结果工具在画布底部横向排列', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 82,
              child: TabletResultToolbar(
                result: ResultImage(
                  id: 'toolbar-test',
                  width: 1216,
                  height: 832,
                  seed: 2153765449,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('tablet-result-toolbar')), findsOneWidget);
    expect(find.text('重绘'), findsOneWidget);
    expect(find.text('放大'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
    expect(find.text('重新生成'), findsOneWidget);

    final toolbar = tester.getCenter(
      find.byKey(const ValueKey('tablet-result-toolbar')),
    );
    final content = tester.getCenter(
      find.byKey(const ValueKey('tablet-result-toolbar-content')),
    );
    expect((toolbar.dx - content.dx).abs(), lessThan(1));

    final redraw = tester.getCenter(find.text('重绘'));
    final regenerate = tester.getCenter(find.text('重新生成'));
    expect((redraw.dy - regenerate.dy).abs(), lessThan(1));
    expect(regenerate.dx, greaterThan(redraw.dx));
  });
}
