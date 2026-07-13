import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../data/suggestions.dart' show transCacheRev;
import '../editor_models.dart';
import 'rich_tag_controller.dart';

/// 表面 · 注音流(光标驱动富文本):
/// 一个真正可编辑的 [TextField](光标点哪改哪、词内可改字、权重原样显示),
/// 下叠 [_FuriganaPainter],按每枚标签**名字范围**把中文当「注音」画在下方。
/// 二者共用同一套文本布局,故翻译与词严格对齐。
/// (排序模式由 SortChipsView 整体替换本视图,这里不再承担排序职责。)
class AnnotatedField extends StatelessWidget {
  const AnnotatedField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    this.scrollController,
  });

  final RichTagController controller;
  final FocusNode focusNode;
  final String hint;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pal = context.editor;
    final scaler = MediaQuery.textScalerOf(context);

    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: controller,
                    builder: (_, _) => CustomPaint(
                      painter: _FuriganaPainter(
                        text: controller.text,
                        // RenderEditable 排版时给光标留 cursorWidth+1 的边距,
                        // 注音层必须用同一宽度重排,否则临界行折点不一致,
                        // 折点一岔开整行注音全错位(真机截图踩过)。
                        maxWidth: width - _kCaretMargin,
                        color: scheme.onSurfaceVariant,
                        scaler: scaler,
                        revision: transCacheRev,
                      ),
                    ),
                  ),
                ),
              ),
              TextField(
                controller: controller,
                focusNode: focusNode,
                style: kEditorBaseStyle.copyWith(color: scheme.onSurface),
                maxLines: null,
                cursorColor: pal.cursor,
                cursorWidth: _kCursorWidth,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  isDense: true,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  hintText: hint,
                  hintStyle: kEditorBaseStyle.copyWith(color: scheme.outline),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static const _kCursorWidth = 2.0;

  /// RenderEditable 的 _caretMargin = cursorWidth + _kCaretGap(1)。
  static const _kCaretMargin = _kCursorWidth + 1.0;
}

/// 翻译当「注音」:始终单行,左端钉词首;地皮由词尾宽度补偿保证
/// (tag 占位 = max(英文, 译文));行尾放不下先回夹再尾截兜底。
class _FuriganaPainter extends CustomPainter {
  _FuriganaPainter({
    required this.text,
    required this.maxWidth,
    required this.color,
    required this.scaler,
    required this.revision,
  });

  final String text;
  final double maxWidth;
  final Color color;
  final TextScaler scaler;

  /// 翻译缓存版本(suggestions.transCacheRev):文本没变但缓存灌到了也要重绘。
  final int revision;

  static const _transSize = 9.5;
  static const _gap = 3.0; // 基线到译文顶的间距

  @override
  void paint(Canvas canvas, Size size) {
    if (text.isEmpty || maxWidth <= 0) return;

    final layout = TextPainter(
      // measureSpan:与 TextField 同款宽度补偿,布局同构
      text: measureSpan(text, scaler),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: null,
    )..layout(maxWidth: maxWidth);

    final lines = layout.computeLineMetrics();
    if (lines.isEmpty) return;
    final lineTops = <double>[];
    var acc = 0.0;
    for (final l in lines) {
      lineTops.add(acc);
      acc += l.height;
    }

    final transStyle = TextStyle(fontSize: _transSize, height: 1, color: color);

    // 收集(行号, 词左端, 译文, 排好版的画笔),按行从左到右画
    final items = <(int, double, String, TextPainter)>[];
    for (final tok in parseToks(text)) {
      final tr = tok.trans;
      if (tr == null || tr.isEmpty || tok.nameEnd <= tok.nameStart) continue;

      final boxes = layout.getBoxesForSelection(
        TextSelection(baseOffset: tok.nameStart, extentOffset: tok.nameEnd),
      );
      if (boxes.isEmpty) continue;

      final tp = TextPainter(
        text: TextSpan(text: tr, style: transStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();

      // 跨行折断的词:首段右侧全是本词自己的延续(无邻居竞争地皮),
      // 译文放得下就画首段(阅读起点);放不下(首段顶在行尾)才退到
      // 带宽度预算的末段。单行词首末同段,无差。
      final b = (boxes.length == 1 || tp.width <= maxWidth - boxes.first.left)
          ? boxes.first
          : boxes.last;
      final mid = (b.top + b.bottom) / 2;
      var li = 0;
      for (var i = 0; i < lines.length; i++) {
        if (mid >= lineTops[i] && mid < lineTops[i] + lines[i].height) {
          li = i;
          break;
        }
      }
      items.add((li, b.left, tr, tp));
    }
    items.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2.compareTo(b.$2));

    // 常规:左端钉词首,原样完整绘制。行尾/文本尾的长译文兜底:
    // 先向左回夹到右边界,撞到同行前一条译文即止(防重叠),
    // 仍放不下才尾部省略(只有这个物理极限场景才截)。
    var lastLine = -1;
    var lastRight = double.negativeInfinity;
    for (final (li, left, tr, tp0) in items) {
      if (li != lastLine) {
        lastLine = li;
        lastRight = double.negativeInfinity;
      }
      var tp = tp0;
      var x = left;
      if (x + tp.width > maxWidth) x = maxWidth - tp.width; // 行尾回夹
      final floor = lastRight.isFinite ? lastRight + 6 : 0.0;
      if (x < floor) x = floor; // 防重叠/防出左界
      if (x + tp.width > maxWidth) {
        tp.dispose();
        tp = TextPainter(
          text: TextSpan(text: tr, style: transStyle),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: (maxWidth - x).clamp(0.0, maxWidth));
      }
      tp.paint(canvas, Offset(x, lines[li].baseline + _gap));
      lastRight = x + tp.width;
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _FuriganaPainter old) =>
      old.text != text ||
      old.maxWidth != maxWidth ||
      old.color != color ||
      old.revision != revision;
}
