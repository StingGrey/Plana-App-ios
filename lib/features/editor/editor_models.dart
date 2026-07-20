/// 提示词编辑器模型 —— 光标驱动定稿:**字符串(含权重原样语法)就是唯一真相**。
///
/// 权重两套**独立**语法叠加在同一枚标签上:
/// - 外层**括号** `{...}` / `[...]`:每层 ×1.05 / ÷1.05,`{ }`/`[ ]` 快捷键各套一层(互不换算)。
/// - 内层**数值** `N::name::`:`−`/`+` 只改这个数,不动括号。
/// 一枚 token 结构:`~ {{ [ N::name:: ] }} ~`(禁用 · 括号层 · 数值 · 名字)。
/// 有效倍率 = 数值 × 1.05^括号净档。翻译画在最内层名字下。
library;

import 'dart:math' as math;

import 'data/suggestions.dart';

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

/// 一枚标签的解析视图(全部是原字符串里的绝对下标)
class Tok {
  const Tok({
    required this.segStart,
    required this.segEnd,
    required this.coreStart,
    required this.coreEnd,
    required this.innerStart,
    required this.innerEnd,
    required this.nameStart,
    required this.nameEnd,
    required this.braceLevel,
    required this.numMult,
    required this.disabled,
    required this.name,
    this.trans,
    this.groupMult = 1.0,
  });

  /// 整枚(含 ~)
  final int segStart;
  final int segEnd;

  /// 剥掉 ~ 后的核(括号 + 数值 + 名字)—— 括号快捷键在这层套/剥
  final int coreStart;
  final int coreEnd;

  /// 剥掉外层括号后(数值 + 名字)—— 数值加减改这层
  final int innerStart;
  final int innerEnd;

  /// 最内层干净名字 —— 翻译画在这段下方
  final int nameStart;
  final int nameEnd;

  final int braceLevel; // 括号净档:+n = n 层 {},-n = n 层 []
  final double numMult; // 内层数值倍率(无则 1.0)
  final bool disabled;
  final String name;
  final String? trans;

  /// 跨词条权重组(`{a, b}` / `1.2::a, b::`)作用于本词的合成倍率(无则 1)。
  /// 组记号本身在 seg 之外(属于分隔区),故删词/清权重天然不碰组语法。
  final double groupMult;

  /// 自身倍率(不含组):数值 × 1.05^括号档。词条栏读数/操作用它。
  double get ownMult => numMult * math.pow(1.05, braceLevel).toDouble();

  /// 有效倍率 = 自身 × 组倍率
  double get effMult => ownMult * groupMult;
}

/// 权重可视化区间(权重底色绘制层用):[start, end) 为原文范围(**含**
/// 权重记号),mult 为该层单独的倍率。嵌套组/组内自带权重 = 多条区间
/// 叠加,绘制层半透明叠色,内层自然更深(web 装饰同款观感)。
class WeightSpan {
  const WeightSpan(this.start, this.end, this.mult);
  final int start;
  final int end;
  final double mult;
}

/// 数值组/数值权重前缀 `N::`。
final _numPrefixRe = RegExp(r'^(-?\d+(?:\.\d+)?)::');

/// 跨词条权重组栈条目:brace=`{`/`[`,否则数值组。openPos=开记号原文下标。
class _Group {
  const _Group(this.brace, this.mult, this.openPos);
  final bool brace;
  final double mult;
  final int openPos;
}

/// 解析整段文本 → 标签列表。
/// 支持**跨词条权重组**(web analyzeTagGroups 对应):`{a, b}`、`[a, b]`、
/// `1.2::a, b::` —— 组记号剥在词条 seg 之外,组倍率灌进成员的 groupMult。
/// 不闭合的组容忍地延伸到文末;记号错配时只剥字符不计权(宽松解析)。
/// 传入 [weightSpans] 时顺带收集权重可视化区间(单词条自身权重一条,
/// 每层组一条,含记号;禁用词条不发自身区间)。
List<Tok> parseToks(String text, {List<WeightSpan>? weightSpans}) {
  final res = <Tok>[];
  var start = 0;
  final groups = <_Group>[];

  int trimL(int a, int b) {
    while (a < b && _isSpace(text[a])) {
      a++;
    }
    return a;
  }

  int trimR(int a, int b) {
    while (b > a && _isSpace(text[b - 1])) {
      b--;
    }
    return b;
  }

  void seg(int rawStart, int rawEnd) {
    var a = trimL(rawStart, rawEnd);
    var b = trimR(a, rawEnd);
    if (b <= a) return;
    final segS = a, segE = b;
    var groupMult = 1.0;
    for (final g in groups) {
      groupMult *= g.mult;
    }

    // 剥禁用 ~
    var disabled = false;
    if (text[a] == '~') {
      disabled = true;
      a++;
      if (b > a && text[b - 1] == '~') b--;
      a = trimL(a, b);
      b = trimR(a, b);
    }
    final coreS = a, coreE = b;

    // 剥外层括号(统计净档)
    var braceLevel = 0;
    var ia = a, ib = b;
    while (ib - ia >= 2) {
      if (text[ia] == '{' && text[ib - 1] == '}') {
        braceLevel++;
      } else if (text[ia] == '[' && text[ib - 1] == ']') {
        braceLevel--;
      } else {
        break;
      }
      ia++;
      ib--;
      ia = trimL(ia, ib);
      ib = trimR(ia, ib);
    }
    final innerS = ia, innerE = ib;

    // 剥内层数值 N::name::
    var numMult = 1.0;
    var nameS = ia, nameE = ib;
    final inner = text.substring(ia, ib);
    final di = inner.indexOf('::');
    final dj = inner.lastIndexOf('::');
    if (di > 0 && dj > di && dj == inner.length - 2) {
      final num = double.tryParse(inner.substring(0, di));
      if (num != null) {
        numMult = num;
        nameS = trimL(ia + di + 2, ib);
        nameE = trimR(nameS, ia + dj);
      }
    }

    res.add(
      Tok(
        segStart: segS,
        segEnd: segE,
        coreStart: coreS,
        coreEnd: coreE,
        innerStart: innerS,
        innerEnd: innerE,
        nameStart: nameS,
        nameEnd: nameE,
        braceLevel: braceLevel,
        numMult: numMult,
        disabled: disabled,
        name: text.substring(nameS, nameE),
        trans: translationOf(text.substring(nameS, nameE)),
        groupMult: groupMult,
      ),
    );
    if (weightSpans != null && !disabled) {
      final own = numMult * math.pow(1.05, braceLevel).toDouble();
      if ((own - 1).abs() > 0.0001) {
        weightSpans.add(WeightSpan(segS, segE, own));
      }
    }
  }

  /// 一段逗号/换行间的 span:先剥跨词条组记号(空 span 也要记账,
  /// `{` 或 `1.2::` 可独占一段),剩余交给 seg 按单词条解析。
  void span(int rawStart, int rawEnd) {
    var a = trimL(rawStart, rawEnd);
    var b = trimR(a, rawEnd);

    // 括号净差:>0 = 本段有未闭合的组开,<0 = 有替前文收口的组闭。
    // (标签名不含花/方括号,直接计数即可;单词条权重 `{a}` 差为 0 不受扰)
    var bal = 0;
    for (var k = a; k < b; k++) {
      final c = text[k];
      if (c == '{' || c == '[') {
        bal++;
      } else if (c == '}' || c == ']') {
        bal--;
      }
    }
    while (a < b && (text[a] == '{' || text[a] == '[') && bal > 0) {
      groups.add(_Group(true, text[a] == '{' ? 1.05 : 1 / 1.05, a));
      a++;
      bal--;
    }
    // 闭记号的**独占尾界**(右→左剥;倒序遍历 = 由内而外出栈)
    final closeEnds = <int>[];
    while (b > a && (text[b - 1] == '}' || text[b - 1] == ']') && bal < 0) {
      closeEnds.add(b);
      b--;
      bal++;
    }
    a = trimL(a, b);
    b = trimR(a, b);

    // 数值组:`N::` 前缀且本段没有属于它的尾部 `::` → 开组;
    // 无前缀但尾部 `::` 且栈顶是数值组 → 收口。完整单词条 `N::a::` 不受扰。
    var numClose = false;
    var numCloseEnd = 0;
    final sub = text.substring(a, b);
    final pm = _numPrefixRe.firstMatch(sub);
    if (pm != null && !(sub.endsWith('::') && sub.length - 2 >= pm.end)) {
      final v = double.tryParse(pm.group(1)!);
      if (v != null) {
        groups.add(_Group(false, v, a));
        a = trimL(a + pm.end, b);
      }
    } else if (pm == null &&
        sub.endsWith('::') &&
        groups.isNotEmpty &&
        !groups.last.brace) {
      numClose = true;
      numCloseEnd = b;
      b = trimR(a, b - 2);
    }

    seg(a, b);

    // 组闭出栈:先内层数值,再括号(错配时跳过,宽松容忍)
    if (numClose && groups.isNotEmpty && !groups.last.brace) {
      final g = groups.removeLast();
      weightSpans?.add(WeightSpan(g.openPos, numCloseEnd, g.mult));
    }
    for (final endPos in closeEnds.reversed) {
      if (groups.isNotEmpty && groups.last.brace) {
        final g = groups.removeLast();
        weightSpans?.add(WeightSpan(g.openPos, endPos, g.mult));
      } else {
        break;
      }
    }
  }

  for (var k = 0; k < text.length; k++) {
    final c = text[k];
    // 换行也是分隔:回车开新行即下一枚标签(名字里不留 \n,翻译反查才有命中)
    if (c == ',' || c == '，' || c == '\n') {
      span(start, k);
      start = k + 1;
    }
  }
  span(start, text.length);
  // 未闭合的组容忍延伸到文末(可视化区间同样兜到文末)
  if (weightSpans != null) {
    for (final g in groups.reversed) {
      weightSpans.add(WeightSpan(g.openPos, text.length, g.mult));
    }
  }
  return res;
}

/// 光标偏移 → 所在标签下标(区间含端点),无则 -1
int tokIndexAt(String text, int offset, [List<Tok>? toks]) {
  final t = toks ?? parseToks(text);
  for (var i = 0; i < t.length; i++) {
    if (offset >= t[i].segStart && offset <= t[i].segEnd) return i;
  }
  return -1;
}

/// 倍率显示:去掉尾随 0(1.30→"1.3"、1.00→"1"、1.05→"1.05")
String fmtMult(double m) {
  var s = m.toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// 括号快捷键:给整个核**外套**一层 `{}`(up)或 `[]`,不动内层数值
String wrapBracket(String text, Tok t, {required bool up}) {
  final core = text.substring(t.coreStart, t.coreEnd);
  final s = up ? '{$core}' : '[$core]';
  return text.replaceRange(t.coreStart, t.coreEnd, s);
}

/// 数值加减:只改内层 `N::name::`(≈1.0 写回纯名),保留外层括号。
/// 不设上下限,支持负数(如 `-0.5::tag::`)。
String setTokMult(String text, Tok t, double newMult) {
  // 抹平浮点漂移:保留两位小数(0.05 步进的最小粒度)
  final m = (newMult * 100).roundToDouble() / 100;
  final inner = (m - 1.0).abs() < 0.005 ? t.name : '${fmtMult(m)}::${t.name}::';
  return text.replaceRange(t.innerStart, t.innerEnd, inner);
}

/// 清除权重:去掉全部括号 + 数值,回纯名(保留禁用 ~)
String clearWeight(String text, Tok t) =>
    text.replaceRange(t.coreStart, t.coreEnd, t.name);

/// 切换禁用:整枚套/剥 `~`
String toggleTokDisabled(String text, Tok t) => t.disabled
    ? text.replaceRange(
        t.segStart,
        t.segEnd,
        text.substring(t.coreStart, t.coreEnd),
      )
    : text.replaceRange(
        t.segStart,
        t.segEnd,
        '~${text.substring(t.segStart, t.segEnd)}~',
      );

/// 删除某枚(连同一个相邻逗号)→ (新文本, 光标位置)
// ---- 划词多选批量操作(web multiSelectActions 移植)----
// 加权/数值走**整组包裹**(`{a, b}` / `1.2::a, b::`,web 同款,解析器已支持
// 跨词条组);禁用逐词应用(保留各自权重);删除按范围整段删。

/// 多选范围 = 分隔符边界:first 左至上一逗号/行首之后,last 右至下一
/// 逗号/行尾之前 —— 把词条两侧的**组权重记号**一并纳入(改写时不留残渣)。
(int, int) _rangeBounds(String text, Tok first, Tok last) {
  var a = first.segStart;
  while (a > 0 &&
      text[a - 1] != ',' &&
      text[a - 1] != '，' &&
      text[a - 1] != '\n') {
    a--;
  }
  while (a < first.segStart && (text[a] == ' ' || text[a] == '\t')) {
    a++;
  }
  var b = last.segEnd;
  while (b < text.length &&
      text[b] != ',' &&
      text[b] != '，' &&
      text[b] != '\n') {
    b++;
  }
  while (b > last.segEnd && (text[b - 1] == ' ' || text[b - 1] == '\t')) {
    b--;
  }
  return (a, b);
}

int _clampLast(List<Tok> toks, int last) =>
    last < toks.length ? last : toks.length - 1;

/// 批量套括号:整段外包一层 `{...}`(up)或 `[...]`(已有权重原样嵌套)。
String batchWrap(String text, int first, int last, {required bool up}) {
  final toks = parseToks(text);
  if (toks.isEmpty || first >= toks.length) return text;
  final l = _clampLast(toks, last);
  final (a, b) = _rangeBounds(text, toks[first], toks[l]);
  final sub = text.substring(a, b);
  return text.replaceRange(a, b, up ? '{$sub}' : '[$sub]');
}

/// 选中范围重建为干净名字串(保留禁用 ~;范围内换行摊平为「, 」)。
String _cleanJoin(String text, List<Tok> toks, int first, int last) => [
  for (var i = first; i <= last; i++)
    toks[i].disabled ? '~${toks[i].name}~' : toks[i].name,
].join(', ');

/// 批量统一数值权重:先清各枚权重,整段写成 `m::a, b::`(≈1 只清不包)。
String batchSetMult(String text, int first, int last, double m) {
  final toks = parseToks(text);
  if (toks.isEmpty || first >= toks.length) return text;
  final l = _clampLast(toks, last);
  final mm = (m * 100).roundToDouble() / 100;
  final cleaned = _cleanJoin(text, toks, first, l);
  final result = (mm - 1.0).abs() < 0.005
      ? cleaned
      : '${fmtMult(mm)}::$cleaned::';
  final (a, b) = _rangeBounds(text, toks[first], toks[l]);
  return text.replaceRange(a, b, result);
}

/// 批量清除权重:整段回干净名字串(组记号/括号/数值全去)。
String batchClearWeight(String text, int first, int last) {
  final toks = parseToks(text);
  if (toks.isEmpty || first >= toks.length) return text;
  final l = _clampLast(toks, last);
  final (a, b) = _rangeBounds(text, toks[first], toks[l]);
  return text.replaceRange(a, b, _cleanJoin(text, toks, first, l));
}

/// 逐词应用(倒序,前面词下标不漂移),每步重扫。禁用批量用。
String _batchEach(
  String text,
  int first,
  int last,
  String Function(String, Tok) op,
) {
  var out = text;
  for (var i = last; i >= first; i--) {
    final toks = parseToks(out);
    if (i >= toks.length) continue;
    out = op(out, toks[i]);
  }
  return out;
}

/// 批量设置禁用状态(web 语义:第一枚的状态决定目标,全体对齐)。
/// 逐词应用,保留各自权重与组记号。
String batchSetDisabled(String text, int first, int last, bool disabled) =>
    _batchEach(
      text,
      first,
      last,
      (s, t) => t.disabled == disabled ? s : toggleTokDisabled(s, t),
    );

/// 批量删除:整段(含组记号)连一侧分隔一起删,返回 (新文本, 光标)。
(String, int) batchDelete(String text, int first, int last) {
  final toks = parseToks(text);
  if (toks.isEmpty || first >= toks.length) return (text, 0);
  final l = _clampLast(toks, last);
  var (a, b) = _rangeBounds(text, toks[first], toks[l]);
  // 同 deleteTok:优先吞右侧逗号,否则吞左侧
  var e = b;
  while (e < text.length && (text[e] == ' ' || text[e] == '\t')) {
    e++;
  }
  if (e < text.length && (text[e] == ',' || text[e] == '，')) {
    e++;
    while (e < text.length && text[e] == ' ') {
      e++;
    }
    b = e;
  } else {
    var st = a;
    while (st > 0 && text[st - 1] == ' ') {
      st--;
    }
    if (st > 0 && (text[st - 1] == ',' || text[st - 1] == '，')) {
      st--;
      while (st > 0 && text[st - 1] == ' ') {
        st--;
      }
      a = st;
    }
  }
  final out = text.replaceRange(a, b, '');
  return (out, a.clamp(0, out.length));
}

// ---- SD WebUI 权重语法(web isSDWeightFormat / convertSDToNAI 移植)----

final _sdWeightRe = RegExp(r'^\((.+?)(?::(-?\d+(?:\.\d+)?))?\)$');

/// 词条是否为 SD 权重语法 `(tag:1.2)` 或 `(tag)`。
bool isSdWeightSeg(String seg) => _sdWeightRe.hasMatch(seg.trim());

/// SD → NAI 转换:`(tag)`→`{tag}`;`(tag:≈1)`→纯名;`(tag:w)`→`w::tag::`。
/// 非 SD 语法原样返回。下划线还原为空格(app 内标签统一空格形式)。
String sdToNaiSeg(String seg) {
  final m = _sdWeightRe.firstMatch(seg.trim());
  if (m == null) return seg;
  final tag = m.group(1)!.replaceAll('_', ' ').trim();
  final w = m.group(2) == null ? null : double.tryParse(m.group(2)!);
  if (w == null) return '{$tag}';
  if ((w - 1.0).abs() < 0.01) return tag;
  return '${fmtMult(w)}::$tag::';
}

/// 异常权重检测(web detectAbnormalWeight 同款):词条内层文本**中段**出现
/// `N::` 且 N≥[threshold](设置里可调,默认 10)——多半是丢了逗号,
/// 把「10::tag::」并进了上一枚词。词首的合法数值权重(如 `1.2::sky::`)
/// 不算。返回可疑数字串,无异常 null。
String? abnormalWeightOf(String text, Tok t, {double threshold = 10}) {
  if (t.innerEnd <= t.innerStart) return null;
  final inner = text.substring(t.innerStart, t.innerEnd);
  for (final m in RegExp(r'(\d+(?:\.\d+)?)::').allMatches(inner)) {
    if (m.start == 0) continue; // 词首 = 合法数值权重
    if ((double.tryParse(m.group(1)!) ?? 0) >= threshold) return m.group(1);
  }
  return null;
}

(String, int) deleteTok(String text, Tok t) {
  var a = t.segStart, b = t.segEnd;
  var e = b;
  while (e < text.length && (text[e] == ' ' || text[e] == '\t')) {
    e++;
  }
  if (e < text.length && (text[e] == ',' || text[e] == '，')) {
    e++;
    while (e < text.length && text[e] == ' ') {
      e++;
    }
    b = e;
  } else {
    var st = a;
    while (st > 0 && text[st - 1] == ' ') {
      st--;
    }
    if (st > 0 && (text[st - 1] == ',' || text[st - 1] == '，')) {
      st--;
      while (st > 0 && text[st - 1] == ' ') {
        st--;
      }
      a = st;
    }
  }
  return (text.replaceRange(a, b, ''), a);
}

/// 词条重排(排序清单用):把第 [from] 枚移到 [to](移除后下标)。
/// 槽位填充:每枚的原样文本(含权重/禁用语法)按新顺序填回原有的
/// N 个槽,槽间分隔(逗号/换行/空格)原样保留——用户排版不被打平。
String reorderToks(String text, int from, int to) {
  final toks = parseToks(text);
  if (from < 0 || from >= toks.length || from == to) return text;
  final segs = [for (final t in toks) text.substring(t.segStart, t.segEnd)];
  final moved = segs.removeAt(from);
  segs.insert(to.clamp(0, segs.length), moved);
  var out = text;
  for (var i = toks.length - 1; i >= 0; i--) {
    out = out.replaceRange(toks[i].segStart, toks[i].segEnd, segs[i]);
  }
  return out;
}

/// 输出串:**原样保留**(换行/间距/权重语法都不动),仅剔除禁用项
/// (连同邻近逗号,同 deleteTok)。回写生成页 + 计 token。
/// 早期按段 join(', ') 重组会抹掉用户换行,故改为原文剔除式。
String outputOf(String text) {
  var out = text;
  while (true) {
    Tok? victim;
    for (final t in parseToks(out)) {
      if (t.disabled) {
        victim = t;
        break;
      }
    }
    if (victim == null) break;
    final (next, _) = deleteTok(out, victim);
    out = next; // deleteTok 必删非空段,长度严格递减,不会死循环
  }
  return out.trim();
}

int estimateTokens(String output) =>
    (output.length / 2.2).round().clamp(0, 999);
