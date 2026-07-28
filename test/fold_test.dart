import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/features/editor/editor_models.dart';

/// 折叠组 `<#名字: a, b>`:仅编辑期语法,记号必须能被解析出来、能被
/// [outputOf] 剥干净、不与既有的权重组/禁用语法互相踩踏,
/// 且**绝不误伤真实提示词**(见最后一组对抗用例)。
void main() {
  test('基本解析:记号剥进分隔区,成员词条名字干净', () {
    const t = 'a, <#画风: b, c>, d';
    final folds = <FoldSpan>[];
    final toks = parseToks(t, folds: folds);

    expect([for (final k in toks) k.name], ['a', 'b', 'c', 'd']);
    expect(folds, hasLength(1));
    final f = folds.single;
    expect(f.name, '画风');
    expect(f.holds(toks[0]), isFalse);
    expect(f.holds(toks[1]), isTrue);
    expect(f.holds(toks[2]), isTrue);
    expect(f.holds(toks[3]), isFalse);
  });

  test('outputOf 剥掉记号只留内容,NAI 侧看不到折叠', () {
    expect(outputOf('a, <#画风: b, c>, d'), 'a, b, c, d');
    expect(outputOf('<#画风: b, c>'), 'b, c');
  });

  test('折叠与权重叠加:括号组与数值权重原样活在折叠体内', () {
    const t = '<#画风: {b}, 1.2::c::>';
    final folds = <FoldSpan>[];
    final toks = parseToks(t, folds: folds);

    expect(toks, hasLength(2));
    expect(toks[0].name, 'b');
    expect(toks[0].braceLevel, 1);
    expect(toks[1].name, 'c');
    expect(toks[1].numMult, closeTo(1.2, 1e-9));
    expect(folds.single.name, '画风');
    expect(outputOf(t), '{b}, 1.2::c::');
  });

  test('成员全禁用 → 空折叠整只删掉,不留 `, ,` 空段', () {
    expect(outputOf('a, <#n: ~b~>, c'), 'a, c');
    expect(outputOf('<#n: ~b~>'), '');
    // 部分禁用照常:剩下的成员留在折叠里
    expect(outputOf('a, <#n: ~b~, c>, d'), 'a, c, d');
  });

  test('创建与解散往返:内容一字不改', () {
    const t = 'a, b, c';
    final folded = foldRange(t, 1, 2, '画风');
    expect(folded, 'a, <#画风: b, c>');
    expect(outputOf(folded), t);

    // 编辑器视角:收成占位符 → 点标题解散 → 内容平铺回来
    final (display, bodies) = collapseFolds(folded);
    expect(display, 'a, ​#画风​');
    final r = parseFoldRefs(display, bodies).single;
    expect(unfoldRef(display, r, bodies), t);
  });

  test('不嵌套:区间与既有折叠交叠则拒绝创建', () {
    const t = 'a, <#n: b, c>, d';
    // 0..2 覆盖 a 与折叠内的 b、c → 与既有折叠交叠,原样返回
    expect(canFoldRange(t, 0, 2), isFalse);
    expect(foldRange(t, 0, 2, 'x'), t);
    // 折叠之外的散装词条照常可折
    expect(canFoldRange(t, 3, 3), isTrue);
  });

  test('颜文字 tag 长得像记号也能折(判交叠而不是扫尖括号)', () {
    const t = '1girl, >_<, <3';
    expect(canFoldRange(t, 1, 2), isTrue);
    final folded = foldRange(t, 1, 2, '表情');
    expect(folded, '1girl, <#表情: >_<, <3>');
    expect(outputOf(folded), t); // 往返一字不改
  });

  test('批量加权不吞折叠记号:包出来是 <#n: {a, b}> 而非 {<#n: a, b}>', () {
    const t = '<#n: a, b>';
    final wrapped = batchWrap(t, 0, 1, up: true);
    expect(wrapped, '<#n: {a, b}>');

    // 记号没错位,折叠仍解析得出,组权重灌进两枚成员
    final folds = <FoldSpan>[];
    final toks = parseToks(wrapped, folds: folds);
    expect(folds.single.name, 'n');
    expect(toks, hasLength(2));
    expect(toks[0].groupMult, closeTo(1.05, 1e-9));
    expect(toks[1].groupMult, closeTo(1.05, 1e-9));
    expect(outputOf(wrapped), '{a, b}');
  });

  test('名字合法化:分隔与记号字符会毁解析,建组时就抹平', () {
    const t = 'a, b';
    // 逗号/冒号/尖括号进名字会让记号错位,统一换成空格
    expect(foldRange(t, 0, 1, 'x,y:z'), '<#x y z: a, b>');
    expect(foldRange(t, 0, 1, '  '), '<#折叠: a, b>'); // 空名兜底
  });

  test('未闭合的折叠容忍到文末(边打字边成组时不闪断)', () {
    const t = 'a, <#n: b';
    final folds = <FoldSpan>[];
    final toks = parseToks(t, folds: folds);
    expect([for (final k in toks) k.name], ['a', 'b']);
    expect(folds.single.name, 'n');
    expect(outputOf(t), 'a, b');
  });

  // 折叠记号是**唯一**会被 outputOf 改写的编辑期语法(禁用词是另一处),
  // 一旦匹配过宽就等于把用户的提示词静默改写后发给 NAI。这组用例把
  // 「什么绝不能被当成折叠」钉死。早期的 `<名字:` 记号在这里全线失守:
  // `<lora:x:0.8>` 会被剥成 `x:0.8`。
  test('对抗输入:真实提示词一个字都不能被改写', () {
    const untouched = [
      // Danbooru 颜文字 tag
      '1girl, >_<, smile',
      '1girl, <o>_<o>, smile',
      '1girl, :<, smile',
      '1girl, >:(, angry',
      '1girl, <3, heart',
      // SD 生态语法(本 app 带 SD→NAI 转换工具,用户会粘这类串)
      '1girl, <lora:anime_style:0.8>, smile',
      '1girl, <hypernet:foo:1>, smile',
      '<lora:a:1>',
      // 缺哨兵:冒号加空格也不够
      '1girl, <备注: 这是说明>, smile',
      // 缺冒号空格:有哨兵也不够
      '1girl, <#note:tight>, smile',
      // 散落的尖括号
      '1girl, a>, b',
      '1girl, <, >',
    ];
    for (final t in untouched) {
      expect(outputOf(t), t, reason: '被改写了:$t');
      expect(parseFolds(t), isEmpty, reason: '被误判为折叠:$t');
    }
  });

  test('foldWrap:单枚不折、已含折叠不嵌套、空串原样', () {
    expect(foldWrap('画风', 'a, b, c'), '<#画风: a, b, c>');
    expect(foldWrap('画风', 'a'), 'a'); // 折一枚没意义
    expect(foldWrap('画风', '  '), '');
    expect(foldWrap('外', '<#内: a, b>'), '<#内: a, b>'); // 不嵌套
  });

  // ---- 占位符层:折叠体不进正文,正文只有 `<#名字>` + 旁路表 ----
  // 此前靠渲染层「藏字」(fontSize 0.01 / 负 letterSpacing)在真机字形引擎上
  // 接连翻车(撑宽换行 / 鬼缩进)。占位符方案下正文所见即所有,这组用例
  // 钉死 collapse/expand 的往返与降级规则。

  test('collapse:草稿收成占位符 + 表;重名不同体自动加序号', () {
    const draft = 'a, <#画风: b, c>, d';
    final (display, bodies) = collapseFolds(draft);
    expect(display, 'a, ​#画风​, d');
    expect(bodies, {'画风': 'b, c'});
    // 往返:展开回完整语法,定稿一致
    expect(expandFolds(display, bodies), draft);
    expect(outputOf(expandFolds(display, bodies)), 'a, b, c, d');

    // 重名且内容不同 → 第二只加序号;同名同体 → 复用
    final (d2, b2) = collapseFolds('<#n: a, b>, <#n: c, d>, <#n: a, b>');
    expect(d2, '​#n​, ​#n 2​, ​#n​');
    expect(b2, {'n': 'a, b', 'n 2': 'c, d'});
  });

  test('collapse seed:负面侧避开正面已占的名字', () {
    final (_, pos) = collapseFolds('<#n: a, b>');
    final (negText, neg) = collapseFolds('<#n: x, y>', seed: pos);
    expect(negText, '​#n 2​');
    expect(neg, {'n 2': 'x, y'});
  });

  test('expand 降级:占位符被组语法包住时裸铺内容,绝不漏记号', () {
    final bodies = {'n': '1.1::a::, 0.8::b::'};
    // 独占一段 → 还原完整折叠
    expect(expandFolds('x, ​#n​', bodies), 'x, <#n: 1.1::a::, 0.8::b::>');
    // 被 {} 包住 → 裸铺(组权重照常作用于成员,折叠解散)
    final braced = expandFolds('{​#n​}', bodies);
    expect(braced, '{1.1::a::, 0.8::b::}');
    expect(outputOf(braced), braced); // 无残留记号
    // 整只禁用 → 逐成员套 ~,outputOf 全剔
    final disabled = expandFolds('x, ~​#n​~', bodies);
    expect(outputOf(disabled), 'x');
    // 未挂号的孤儿占位符不是折叠:expand 原样直传,outputOf 出口滤掉零宽
    expect(expandFolds('a, ​#杂​', bodies), 'a, ​#杂​');
    expect(outputOf('a, ​#杂​'), 'a, #杂');
  });

  test('折叠标题可见区 = #名字(去两侧尖括号)', () {
    final bodies = {'画风': 'b, c'};
    const display = 'x, ​#画风​';
    final r = parseFoldRefs(display, bodies).single;
    final (a, b) = r.titleRange;
    expect(display.substring(a, b), '#画风');
  });

  test('整只删除占位符:连一侧分隔一起走,不留空段', () {
    final bodies = {'n': 'b, c'};
    const t = 'a, ​#n​, d';
    final r = parseFoldRefs(t, bodies).single;
    expect(deleteFoldRef(t, r), ('a, d', 3));
    // 末尾的占位符吞左侧逗号
    const t2 = 'a, ​#n​';
    expect(deleteFoldRef(t2, parseFoldRefs(t2, bodies).single).$1, 'a');
  });

  test('顶层单元:散标签与占位符各成一单元;重排整块移动', () {
    final bodies = {'n': 'b, c'};
    const t = 'a, ​#n​, d';
    final units = topLevelUnits(t, bodies);
    expect(units, hasLength(3));
    expect(units[0].tok!.name, 'a');
    expect(units[1].isFold, isTrue);
    expect(units[1].fold!.name, 'n');
    expect(units[2].tok!.name, 'd');

    expect(reorderUnits(t, bodies, 1, 0), '​#n​, a, d');
    expect(reorderUnits(t, bodies, 0, 2), '​#n​, d, a');
    // 展开 + 定稿始终干净
    expect(
      outputOf(expandFolds(reorderUnits(t, bodies, 1, 0), bodies)),
      'b, c, a, d',
    );
  });

  test('多选移动:整批搬走,批内相对顺序不变,分隔不增不减', () {
    const t = 'a, b, c, d';
    const bodies = <String, String>{};
    // 搬到末尾(gap = 4)
    expect(moveUnits(t, bodies, [0, 2], 4), 'b, d, a, c');
    // 搬到最前(gap = 0)
    expect(moveUnits(t, bodies, [1, 3], 0), 'b, d, a, c');
    // 搬到中间:gap 3 = 「c 之后、d 之前」,剩下的未选中项只有 b/d
    expect(moveUnits(t, bodies, [0, 2], 3), 'b, a, c, d');
    // 全选 = 无意义,原样返回;越界下标忽略
    expect(moveUnits(t, bodies, [0, 1, 2, 3], 0), t);
    expect(moveUnits(t, bodies, [0, 9], 4), 'b, c, d, a');
  });

  test('多选移动:折叠占位符整块跟着走,展开后成员不散', () {
    final bodies = {'n': 'x, y'};
    const t = 'a, ​#n​, d';
    expect(moveUnits(t, bodies, [1, 2], 0), '​#n​, d, a');
    expect(outputOf(expandFolds(moveUnits(t, bodies, [1, 2], 0), bodies)),
        'x, y, d, a');
  });

  test('多选禁用/删除:折叠不套 ~(套了就散),删除走整只删', () {
    final bodies = {'n': 'x, y'};
    const t = 'a, ​#n​, d';
    // 只有散标签被套上 ~;占位符原样 —— 否则它的区间不再与 tok 段重合,
    // topLevelUnits 会把它降级成普通标签,折叠当场散掉
    final off = setUnitsDisabled(t, bodies, [0, 1, 2], true);
    expect(off, '~a~, ​#n​, ~d~');
    expect(topLevelUnits(off, bodies)[1].isFold, isTrue);
    // 再来一次「启用」回到原样
    expect(setUnitsDisabled(off, bodies, [0, 1, 2], false), t);

    expect(deleteUnits(t, bodies, [0, 1]).$1, 'd');
    expect(deleteUnits(t, bodies, [0, 2]).$1, '​#n​');
  });

  test('token 计数按展开后的定稿算:折叠体不因收起而漏计', () {
    const body =
        '1.1::kazutake_hazano::, 1.3::lobelia(saclia)::, 0.8::ezu (e104mjd)::';
    final (display, bodies) = collapseFolds('<#画风: $body>, 1girl');
    // 展开后的定稿 = 折叠体 + 散标签,计数必须以它为准
    final expanded = outputOf(expandFolds(display, bodies));
    expect(expanded, '$body, 1girl');
    expect(
      estimateTokens(expanded),
      greaterThan(estimateTokens(outputOf(display))),
      reason: '直接对占位符正文计数会把整段折叠体漏掉',
    );
  });

  test('无折叠时行为不变(既有解析不被新语法扰动)', () {
    const t = '1girl, {smile, blue eyes}, 1.2::sky::, ~off~';
    expect(parseFolds(t), isEmpty);
    expect(outputOf(t), '1girl, {smile, blue eyes}, 1.2::sky::');
    final toks = parseToks(t);
    expect(
      [for (final k in toks) k.name],
      ['1girl', 'smile', 'blue eyes', 'sky', 'off'],
    );
  });
}
