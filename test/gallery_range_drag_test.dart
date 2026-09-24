import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/gallery/widgets/gallery_range_picker.dart';

void main() {
  DateTimeRange? result;
  Future<void> mount(
    WidgetTester tester, {
    DateTime? start,
    DateTime? end,
    DateTime? first,
    DateTime? last,
    Size size = const Size(390, 844),
    double scale = 1,
    bool dark = false,
  }) async {
    result = null;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<DateTimeRange>(
                  context: context,
                  builder: (_) => GalleryRangePicker(
                    initialRange: DateTimeRange(
                      start: start ?? DateTime(2026, 9, 3),
                      end: end ?? DateTime(2026, 9, 11),
                    ),
                    firstDate: first ?? DateTime(1900),
                    lastDate: last ?? DateTime(2027, 12, 31),
                    currentDate: DateTime(2026, 9, 21),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Finder date(DateTime day) => find.byKey(ValueKey<DateTime>(day));
  Finder day(int n) => date(DateTime(2026, 9, n));
  Rect grid(WidgetTester tester) => tester.getRect(find.byType(PageView));
  // Dialog 外层铺满全屏,弹窗本体是里面那层 Material。
  Rect surface(WidgetTester tester) => tester.getRect(
    find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first,
  );

  Future<void> drag(WidgetTester tester, Finder from, Finder to) async {
    final target = tester.getCenter(to);
    final gesture = await tester.startGesture(tester.getCenter(from));
    // 没有长按等待，第一笔移动就调整端点。
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  // 端点拖出日历后停到翻页(先等 450ms,再等 200ms 翻页动画)。
  Future<void> holdOutside(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.tap(find.text('应用').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('居中弹窗，版式同单日选择器', (tester) async {
    await mount(tester);
    final dialog = surface(tester);
    expect(dialog.width, lessThanOrEqualTo(390 - 32));
    expect(dialog.height, lessThan(844 - 48));
    expect(find.text('选择日期范围'), findsOneWidget);
    expect(find.text('9月3日 – 9月11日'), findsOneWidget);
    expect(find.text('2026年9月'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('直接拖动终点，月份不动', (tester) async {
    await mount(tester);
    final before = tester.getTopLeft(day(3));
    await drag(tester, day(11), day(25));
    expect(tester.getTopLeft(day(3)), before);
    expect(find.text('2026年9月'), findsOneWidget);
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 9, 3), end: DateTime(2026, 9, 25)),
    );
  });

  testWidgets('拖动起点保留另一端，越过另一端后交换起止', (tester) async {
    await mount(tester);
    await drag(tester, day(3), day(9));
    await drag(tester, day(9), day(16));
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 9, 11), end: DateTime(2026, 9, 16)),
    );
  });

  testWidgets('同一天范围可直接向前扩展', (tester) async {
    await mount(tester, start: DateTime(2026, 9, 11));
    await drag(tester, day(11), day(3));
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 9, 3), end: DateTime(2026, 9, 11)),
    );
  });

  testWidgets('普通日期左右滑动翻月，点选仍可重新选择范围', (tester) async {
    await mount(tester);
    await tester.drag(day(15), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('2026年10月'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('2026年9月'), findsOneWidget);
    await tester.tap(day(5));
    await tester.pumpAndSettle();
    // 只选了起点时不能应用。
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '应用'))
          .onPressed,
      isNull,
    );
    await tester.tap(day(13));
    await tester.pumpAndSettle();
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 9, 5), end: DateTime(2026, 9, 13)),
    );
  });

  testWidgets('拖动被取消时恢复原范围，点取消不应用草稿', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(day(11)));
    await gesture.moveTo(tester.getCenter(day(20)));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 9, 3), end: DateTime(2026, 9, 11)),
    );
    await mount(tester);
    await drag(tester, day(11), day(20));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  for (final (start, end, target) in [
    (DateTime(2026, 9, 3), DateTime(2026, 9, 11), DateTime(2026, 10, 2)),
    (DateTime(2026, 12, 25), DateTime(2026, 12, 30), DateTime(2027, 1, 2)),
    (DateTime(2024, 2, 28), DateTime(2024, 2, 29), DateTime(2024, 3, 1)),
  ]) {
    testWidgets('终点拖到日历下方翻到下个月：$end → $target', (tester) async {
      await mount(tester, start: start, end: end);
      final area = grid(tester);
      final gesture = await tester.startGesture(tester.getCenter(date(end)));
      await gesture.moveTo(Offset(area.center.dx, area.bottom + 20));
      await holdOutside(tester);
      expect(date(target), findsOneWidget);
      await gesture.moveTo(tester.getCenter(date(target)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await apply(tester);
      expect(result, DateTimeRange(start: start, end: target));
    });
  }

  testWidgets('起点拖到日历上方翻到上个月', (tester) async {
    await mount(tester);
    final area = grid(tester);
    final gesture = await tester.startGesture(tester.getCenter(day(3)));
    await gesture.moveTo(Offset(area.center.dx, area.top - 20));
    await holdOutside(tester);
    expect(find.text('2026年8月'), findsOneWidget);
    await gesture.moveTo(tester.getCenter(date(DateTime(2026, 8, 28))));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 8, 28), end: DateTime(2026, 9, 11)),
    );
  });

  testWidgets('按住在日历外连续翻月，回到日历里就停', (tester) async {
    await mount(tester);
    final area = grid(tester);
    final gesture = await tester.startGesture(tester.getCenter(day(11)));
    await gesture.moveTo(Offset(area.center.dx, area.bottom + 20));
    await holdOutside(tester);
    expect(find.text('2026年10月'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2026年11月'), findsOneWidget);
    await gesture.moveTo(tester.getCenter(date(DateTime(2026, 11, 4))));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('2026年11月'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 9, 3), end: DateTime(2026, 11, 4)),
    );
  });

  testWidgets('拖动中关闭弹窗不会遗留翻页或提交日期', (tester) async {
    await mount(tester);
    final area = grid(tester);
    final gesture = await tester.startGesture(tester.getCenter(day(11)));
    await gesture.moveTo(Offset(area.center.dx, area.bottom + 20));
    await tester.pump();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('额外手指轻触不会中断端点拖动', (tester) async {
    await mount(tester);
    final drag = await tester.startGesture(
      tester.getCenter(day(11)),
      pointer: 1,
    );
    await drag.moveTo(tester.getCenter(day(18)));
    await tester.pump();
    final other = await tester.startGesture(
      tester.getCenter(day(9)),
      pointer: 2,
    );
    await other.up();
    await tester.pump();
    await drag.moveTo(tester.getCenter(day(25)));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 9, 3), end: DateTime(2026, 9, 25)),
    );
  });

  testWidgets('拖到范围之外的禁用日期不会选中', (tester) async {
    await mount(
      tester,
      first: DateTime(2026, 9, 1),
      last: DateTime(2026, 9, 20),
    );
    await drag(tester, day(11), day(30));
    await apply(tester);
    expect(result!.end, DateTime(2026, 9, 11));
  });

  testWidgets('点年月切换年份，可以跨年点选', (tester) async {
    await mount(tester);
    Finder year(String y) => find.descendant(
      of: find.byType(YearPicker),
      matching: find.textContaining(y),
    );
    await tester.tap(find.text('2026年9月'));
    await tester.pumpAndSettle();
    await tester.tap(year('2025'));
    await tester.pumpAndSettle();
    expect(find.text('2025年9月'), findsOneWidget);
    await tester.tap(date(DateTime(2025, 9, 10)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2025年9月'));
    await tester.pumpAndSettle();
    await tester.tap(year('2026'));
    await tester.pumpAndSettle();
    await tester.tap(day(11));
    await tester.pumpAndSettle();
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2025, 9, 10), end: DateTime(2026, 9, 11)),
    );
  });

  testWidgets('手输日期保持中文，返回日历保留拖动结果，应用只需一次', (tester) async {
    await mount(tester);
    await drag(tester, day(11), day(20));
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回日历'));
    await tester.pumpAndSettle();
    expect(find.text('9月3日 – 9月20日'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(
      Localizations.localeOf(
        tester.element(find.byType(DateRangePickerDialog)),
      ).languageCode,
      'zh',
    );
    await tester.enterText(find.byType(TextField).first, '2026/10/01');
    await tester.enterText(find.byType(TextField).last, '2026/10/04');
    await apply(tester);
    expect(
      result,
      DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 4)),
    );
  });

  for (final (size, scale, dark) in [
    (const Size(320, 640), 1.5, true),
    (const Size(369, 821), 1.3, false),
    (const Size(844, 390), 1.0, false),
  ]) {
    testWidgets('窄屏大字体和横屏不溢出：$size ×$scale', (tester) async {
      await mount(tester, size: size, scale: scale, dark: dark);
      expect(tester.takeException(), isNull);
      final dialog = surface(tester);
      expect(dialog.width, lessThanOrEqualTo(size.width - 32));
      expect(dialog.height, lessThanOrEqualTo(size.height - 48));
      await drag(tester, day(11), day(17));
      await apply(tester);
      expect(result!.end, DateTime(2026, 9, 17));
    });
  }
}
