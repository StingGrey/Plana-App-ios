import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../editor_models.dart';

/// 富文本域基准样式。行高留高(2.0)给下方翻译预留空间。
/// letterSpacing 必须显式钉 0:TextField 会把主题 titleMedium(M3 带
/// letterSpacing .15)merge 进来,注音层布局却无主题——每字符差 .15px,
/// 累积到临界行翻转断行点,断行一漂整行注音错位(真机截图踩过)。
const TextStyle kEditorBaseStyle = TextStyle(
  fontSize: 16,
  height: 2.0,
  fontWeight: FontWeight.w500,
  letterSpacing: 0,
);

// ---- tag 宽度补偿(web chip 的 max(英文宽, 译文宽) 定总宽,移植到字符串模型)----
// 译文比词宽时,给词尾逗号动态加 letterSpacing 把下一词推开——注音地皮恒足,
// 相邻译文不再重叠。TextField 与注音/圈框/排序层共用同一间距,布局始终同构。

/// 注音字号(与 _FuriganaPainter 的 _transSize 一致,宽度测量用)。
const TextStyle kTransMeasureStyle = TextStyle(fontSize: 9.5, height: 1);

final _widthCache = <String, double>{};

double _textWidth(String s, TextStyle style, TextScaler scaler) {
  final key = '${style.fontSize}|${scaler.scale(100)}|$s';
  final hit = _widthCache[key];
  if (hit != null) return hit;
  final tp = TextPainter(
    text: TextSpan(text: s, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final w = tp.width;
  tp.dispose();
  if (_widthCache.length > 6000) _widthCache.clear();
  return _widthCache[key] = w;
}

/// 需要补偿的字符下标(**词段最后一个字符**)→ 额外 letterSpacing。
/// 附着词尾字符:词内不可断行,断行器把「词+译文预算」当整体处理——
/// 行尾放不下就整词(带译文)折到下一行,译文永不出屏。
Map<int, double> tagExtraSpacing(String text, TextScaler scaler) {
  final out = <int, double>{};
  for (final t in parseToks(text)) {
    final tr = t.trans;
    if (tr == null || tr.isEmpty || t.segEnd <= t.segStart) continue;
    final segW = _textWidth(
      text.substring(t.segStart, t.segEnd),
      kEditorBaseStyle,
      scaler,
    );
    final transW = _textWidth(tr, kTransMeasureStyle, scaler);
    final extra = transW - segW;
    if (extra > 0) out[t.segEnd - 1] = extra;
  }
  return out;
}

/// 布局同构 span(注音/圈框/排序层测量用):纯基准样式 + 同款间距。
TextSpan measureSpan(String text, TextScaler scaler) {
  const base = kEditorBaseStyle;
  final spacing = tagExtraSpacing(text, scaler);
  if (spacing.isEmpty) {
    return TextSpan(text: text, style: base);
  }
  final children = <InlineSpan>[];
  var start = 0;
  for (final k in spacing.keys.toList()..sort()) {
    if (k > start) children.add(TextSpan(text: text.substring(start, k)));
    children.add(
      TextSpan(
        text: text[k],
        style: TextStyle(letterSpacing: spacing[k]),
      ),
    );
    start = k + 1;
  }
  if (start < text.length) children.add(TextSpan(text: text.substring(start)));
  return TextSpan(style: base, children: children);
}

/// 光标驱动编辑器的文本控制器:文本含**原样权重语法**(`N::tag::`/`{}`/`[]`),
/// [buildTextSpan] 现算 token、按方向上色(加权橙 / 降权蓝 / 禁用灰删除线),
/// `::` 标记与逗号淡显。只改颜色不改字号字重,故与翻译绘制层布局一致。
class RichTagController extends TextEditingController {
  RichTagController({super.text});

  /// 文本没变但外部数据到了(翻译缓存灌注完成)时手动触发重建/重绘。
  void refresh() => notifyListeners();

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? kEditorBaseStyle;
    final scheme = context.scheme;
    final pal = context.editor;
    final t = text;
    final toks = parseToks(t);
    final spacing = tagExtraSpacing(t, MediaQuery.textScalerOf(context));

    Color dirColor(Tok tok) {
      if (tok.disabled) return scheme.onSurfaceVariant;
      if (tok.effMult > 1.0001) return pal.weightUp;
      if (tok.effMult < 0.9999) return pal.weightDown;
      return scheme.onSurface;
    }

    // 逐字符着色:token 内=方向色(`:`/`~`/括号淡一档),token 外=分隔色
    final children = <InlineSpan>[];
    final buf = StringBuffer();
    Color? curColor;
    var curStrike = false;
    var ti = 0;

    void flush() {
      if (buf.isEmpty) return;
      children.add(
        TextSpan(
          text: buf.toString(),
          style: base.copyWith(
            color: curColor,
            decoration: curStrike ? TextDecoration.lineThrough : null,
            decorationColor: curColor,
          ),
        ),
      );
      buf.clear();
    }

    for (var k = 0; k < t.length; k++) {
      while (ti < toks.length && toks[ti].segEnd <= k) {
        ti++;
      }
      final inTok =
          ti < toks.length && k >= toks[ti].segStart && k < toks[ti].segEnd;
      Color c;
      var strike = false;
      if (!inTok) {
        c = scheme.outline; // 逗号 / 词间空隙
      } else {
        final tok = toks[ti];
        final ch = t[k];
        final marker =
            ch == ':' ||
            ch == '{' ||
            ch == '}' ||
            ch == '[' ||
            ch == ']' ||
            ch == '~';
        final dc = dirColor(tok);
        c = marker ? dc.withValues(alpha: .45) : dc;
        strike = tok.disabled;
      }
      final sp = spacing[k];
      if (sp != null) {
        // 宽度补偿的逗号:独立 span 携带 letterSpacing(把下一词推开)
        flush();
        children.add(
          TextSpan(
            text: t[k],
            style: base.copyWith(
              color: c,
              decoration: strike ? TextDecoration.lineThrough : null,
              decorationColor: c,
              letterSpacing: sp,
            ),
          ),
        );
        curColor = c;
        curStrike = strike;
        continue;
      }
      if (c != curColor || strike != curStrike) {
        flush();
        curColor = c;
        curStrike = strike;
      }
      buf.write(t[k]);
    }
    flush();

    return TextSpan(style: base, children: children);
  }
}
