// 精简词条栏:三行压成一行。
//
// 这一栏吸在键盘上方,高度直接换成正文能露几行 —— 所以「就是一行」是它的
// 全部意义,多出一行就等于这个模式白开。而它又是纯布局,写错了 analyze
// 一声不吭,只有真跑一帧才看得出来。
//
// 另一条要钉住的是**功能不能少**:权重相关的全部(括号 / 数值加减 / 读数 /
// 清除)加上禁用与删除,一样都不能借着省宽度砍掉。
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
  // 369×800:测试机的真实逻辑尺寸(1200px / 520dpi),精简版的宽度预算按它算。
  // 以前默认 412 是猜的,比真机宽 43 —— 按那个数排出来的行在真机上是挤的。
  Future<void> pumpAt(WidgetTester t, Widget w, {double width = 369}) async {
    t.view.physicalSize = Size(width * 3, 800 * 3);
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
      lessThanOrEqualTo(60),
      reason: '一行 = 控件 40 + 上下各 8 的内边距;超过就是排成两行了',
    );

    await pumpAt(t, _host(compact: false));
    final fullH = t.getSize(find.byType(TagPanel)).height;
    expect(
      compactH,
      lessThan(fullH / 2),
      reason: '砍到一行至少该省掉一半以上,否则这个模式不值得存在',
    );
  });

  testWidgets('功能一个不少:括号 / 加减 / 读数 / 清除 / 禁用 / 删除', (t) async {
    // 带权重才有得清 —— 清除键在无权重时是灰的
    await pumpAt(t, _host(compact: true, tok: _tok(numMult: 1.2)));

    expect(find.text('[ ]'), findsOneWidget, reason: '降权括号');
    expect(find.text('{ }'), findsOneWidget, reason: '加权括号');
    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('×1.2'), findsOneWidget, reason: '读数');
    expect(
      find.byIcon(Icons.backspace_outlined),
      findsOneWidget,
      reason: '清除权重',
    );
    expect(find.byIcon(Icons.visibility_off), findsOneWidget, reason: '禁用');
    expect(find.byIcon(Icons.delete_outline), findsOneWidget, reason: '删除');
    // 关闭去掉了:光标挪开 / 再点一下 chip / 点空白都会收走这一栏,
    // 一枚只为「原地藏起来」的 ✕ 不值 36 宽
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('不显示标签名:那枚词就在正上方的正文里高亮着,抄一遍是复述', (t) async {
    await pumpAt(t, _host(compact: true));
    expect(find.text('blue eyes'), findsNothing);
    expect(find.text('蓝眼'), findsNothing, reason: '译文在正文注音层里有,这儿不重复');
    expect(find.byIcon(Icons.travel_explore), findsNothing);
    expect(find.byIcon(Icons.content_copy), findsNothing);
    expect(find.text('关联'), findsNothing);
    expect(find.text('权重'), findsNothing, reason: '一行里没有给标题的位置');
  });

  testWidgets('×1 也照常显示:读数槽定宽,不让整排键在有无权重之间左右挪', (t) async {
    await pumpAt(t, _host(compact: true));
    expect(find.text('×1'), findsOneWidget);
  });

  testWidgets('括号档也算权重,读数跟着走', (t) async {
    // braceLevel=2 → ×1.05² ≈ 1.1
    await pumpAt(t, _host(compact: true, tok: _tok(braceLevel: 2)));
    expect(find.text('×1.1'), findsOneWidget);
  });

  testWidgets('禁着的时候给一只睁眼:图标报的是按下去会变成什么', (t) async {
    await pumpAt(t, _host(compact: true, tok: _tok(disabled: true)));
    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off), findsNothing);
  });

  testWidgets('警示不再占一整行,压成一枚可点的图标', (t) async {
    await pumpAt(t, _host(compact: true, warning: '10'));
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(
      t.getSize(find.byType(TagPanel)).height,
      lessThanOrEqualTo(60),
      reason: '带警示时也还是一行,不然「一行」这个承诺就是有条件的',
    );
    // 完整版那句话在这儿不该常驻(点图标才说)
    expect(find.textContaining('疑似丢了逗号'), findsNothing);
  });

  testWidgets('按钮比第一版粗一圈:够得上 36 的触摸目标', (t) async {
    await pumpAt(t, _host(compact: true));
    final del = t.getSize(
      find
          .ancestor(
            of: find.byIcon(Icons.delete_outline),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(del.width, greaterThanOrEqualTo(36));
    expect(del.height, greaterThanOrEqualTo(36));
    expect(t.getSize(find.text('{ }')).width, greaterThanOrEqualTo(20));
  });

  testWidgets('窄到放不下就横向可滚,而不是溢出画黄黑条', (t) async {
    await pumpAt(t, _host(compact: true), width: 280);
    expect(t.takeException(), isNull, reason: '不能溢出');
    // 功能一个都不能少
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    expect(find.text('{ }'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('真机宽度上不该退化成可滚:369 / 360 都要能一屏摆下', (t) async {
    for (final w in [369.0, 360.0]) {
      await pumpAt(t, _host(compact: true, tok: _tok(numMult: 1.2)), width: w);
      expect(t.takeException(), isNull, reason: '$w');
      expect(
        find.byType(SingleChildScrollView),
        findsNothing,
        reason: '$w 是真机/常见宽度,再窄才该动用滚动兜底',
      );
    }
  });
}
