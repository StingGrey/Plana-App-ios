// 精简词条栏:三行压成一行。
//
// 这一栏吸在键盘上方,高度直接换成正文能露几行 —— 所以「就是一行」是它的
// 全部意义,多出一行就等于这个模式白开。而它又是纯布局,写错了 analyze
// 一声不吭,只有真跑一帧才看得出来。
//
// 另一条同样要钉住的是**功能不能少**:用户要的是「权重相关的所有功能加删除」,
// 括号、数值加减、清除权重一样都不能借着省宽度砍掉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/widgets/tag_panel.dart';

Tok _tok({
  String name = 'blue eyes',
  int braceLevel = 0,
  double numMult = 1.0,
  bool disabled = false,
  double groupMult = 1.0,
}) => Tok(
  segStart: 0,
  segEnd: name.length,
  coreStart: 0,
  coreEnd: name.length,
  innerStart: 0,
  innerEnd: name.length,
  nameStart: 0,
  nameEnd: name.length,
  braceLevel: braceLevel,
  numMult: numMult,
  disabled: disabled,
  name: name,
  trans: '蓝眼',
  groupMult: groupMult,
);

Widget _host({required bool compact, Tok? tok, String? warning}) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(
    // 词条栏是吸底的,给它一个贴底的宿主,量到的高度就是它真实占的高度
    body: Align(
      alignment: Alignment.bottomCenter,
      child: TagPanel(
        tok: tok ?? _tok(),
        count: 1234567,
        related: const ['blue hair', 'green eyes'],
        compact: compact,
        warning: warning,
        onWrap: (_) {},
        onSetMult: (_) {},
        onClear: () {},
        onToggleDisabled: () {},
        onDelete: () {},
        onAddRelated: (_) {},
        onClose: () {},
      ),
    ),
  ),
);

void main() {
  // 412×892:开发机上那台的逻辑尺寸,精简版的宽度预算是按它算的
  Future<void> pumpAt(WidgetTester t, Widget w, {double width = 412}) async {
    t.view.physicalSize = Size(width * 3, 892 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(w);
    await t.pumpAndSettle();
  }

  testWidgets('精简版就是一行:比完整版矮得多,且不超过一行的高度', (t) async {
    await pumpAt(t, _host(compact: true));
    final compactH = t.getSize(find.byType(TagPanel)).height;
    expect(
      compactH,
      lessThanOrEqualTo(52),
      reason: '一行 = 控件 34 + 上下各 6 的内边距;超过就是排成两行了',
    );

    await pumpAt(t, _host(compact: false));
    final fullH = t.getSize(find.byType(TagPanel)).height;
    expect(
      compactH,
      lessThan(fullH / 2),
      reason: '砍到一行至少该省掉一半以上,否则这个模式不值得存在',
    );
  });

  testWidgets('权重的全部功能都在:括号 / 加减 / 清除,外加删除', (t) async {
    // 带权重才有得清 —— 清除键在无权重时是灰的
    await pumpAt(t, _host(compact: true, tok: _tok(numMult: 1.2)));

    expect(find.text('[ ]'), findsOneWidget, reason: '降权括号');
    expect(find.text('{ }'), findsOneWidget, reason: '加权括号');
    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('×1.2'), findsOneWidget, reason: '读数');
    expect(find.byIcon(Icons.backspace_outlined), findsOneWidget, reason: '清除权重');
    expect(find.byIcon(Icons.delete_outline), findsOneWidget, reason: '删除');
    expect(find.byIcon(Icons.close), findsOneWidget, reason: '关闭');
  });

  testWidgets('收走的东西真的不在:热度 / 译文 / 禁用 / 关联 / 维基 / 复制', (t) async {
    await pumpAt(t, _host(compact: true));
    expect(find.text('禁用'), findsNothing);
    expect(find.text('关联'), findsNothing);
    expect(find.text('清除权重'), findsNothing, reason: '精简版里它是图标不是文字按钮');
    expect(find.text('蓝眼'), findsNothing, reason: '译文在正文注音层里有,这儿不重复');
    expect(find.byIcon(Icons.travel_explore), findsNothing);
    expect(find.byIcon(Icons.content_copy), findsNothing);
    // 名字留着 —— 它是「你在改哪一枚」的唯一凭据
    expect(find.text('blue eyes'), findsOneWidget);
  });

  testWidgets('警示不再占一整行,压成一枚可点的图标', (t) async {
    await pumpAt(t, _host(compact: true, warning: '10'));
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(
      t.getSize(find.byType(TagPanel)).height,
      lessThanOrEqualTo(52),
      reason: '带警示时也还是一行,不然「一行」这个承诺就是有条件的',
    );
    // 完整版那句话在这儿不该常驻(点图标才说)
    expect(find.textContaining('疑似丢了逗号'), findsNothing);
  });

  testWidgets('窄屏挤不下时名字整个让位,而不是挤成一个省略号', (t) async {
    await pumpAt(t, _host(compact: true), width: 300);
    expect(find.text('blue eyes'), findsNothing);
    // 功能一个都不能少
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.text('{ }'), findsOneWidget);
    expect(t.takeException(), isNull, reason: '不能溢出');
  });
}
