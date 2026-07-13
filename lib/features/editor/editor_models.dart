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

  /// 有效倍率 = 数值 × 1.05^括号档
  double get effMult => numMult * math.pow(1.05, braceLevel).toDouble();
}

/// 解析整段文本 → 标签列表
List<Tok> parseToks(String text) {
  final res = <Tok>[];
  var start = 0;

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
      ),
    );
  }

  for (var k = 0; k < text.length; k++) {
    final c = text[k];
    // 换行也是分隔:回车开新行即下一枚标签(名字里不留 \n,翻译反查才有命中)
    if (c == ',' || c == '，' || c == '\n') {
      seg(start, k);
      start = k + 1;
    }
  }
  seg(start, text.length);
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
  // 抹平浮点漂移:保留一位小数
  final m = (newMult * 10).roundToDouble() / 10;
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
