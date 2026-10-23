import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../theme/app_theme.dart';
import '../util/haptics.dart';

/// 右缘快速滚动把手:列表超过两屏时,手指一滚就从右缘浮出,停下一会儿自己收回;
/// 按住上下拖 = 按比例跳到整条列表的对应位置。
///
/// 包在可滚动视图外面即可,不接控制器:位置从滚动通知里取,换了一份列表
/// (换分类、换相册)就跟着新的走。只认最近一层的竖向滚动。
class FastScrollHandle extends StatefulWidget {
  const FastScrollHandle({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  final Widget child;

  /// 滑轨上下留白。
  final EdgeInsets padding;

  @override
  State<FastScrollHandle> createState() => _FastScrollHandleState();
}

class _FastScrollHandleState extends State<FastScrollHandle>
    with SingleTickerProviderStateMixin {
  static const _w = 34.0;
  static const _h = 52.0;
  static const _right = 6.0;
  static const _touchW = 52.0;
  static const _hideDelay = Duration(milliseconds: 1500);

  late final _reveal = AnimationController(
    vsync: this,
    duration: Motion.fast,
    reverseDuration: Motion.medium,
  );

  /// 把手在滑轨上的位置 0..1。
  final _frac = ValueNotifier<double>(0);

  ScrollableState? _scrollable;
  Timer? _hideTimer;
  double _travel = 0;

  bool _dragging = false;
  double _dragFrom = 0;
  double _dragFromY = 0;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _reveal.dispose();
    _frac.dispose();
    super.dispose();
  }

  static double _fracOf(ScrollMetrics m) {
    final range = m.maxScrollExtent - m.minScrollExtent;
    if (range <= 0) return 0;
    return ((m.pixels - m.minScrollExtent) / range).clamp(0.0, 1.0);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final ctx = n.context;
    if (ctx != null) {
      _scrollable = ctx.findAncestorStateOfType<ScrollableState>();
    }
    final m = n.metrics;
    if (!_dragging) _frac.value = _fracOf(m);
    if (n is UserScrollNotification) {
      if (n.direction != ScrollDirection.idle &&
          m.maxScrollExtent - m.minScrollExtent > m.viewportDimension) {
        _hideTimer?.cancel();
        _reveal.forward();
      }
    } else if (n is ScrollEndNotification && !_dragging) {
      _scheduleHide();
    }
    return false;
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (mounted && !_dragging) _reveal.reverse();
    });
  }

  void _dragStart(DragStartDetails d) {
    final s = _scrollable;
    if (s == null || !s.mounted || _travel <= 0) return;
    _hideTimer?.cancel();
    Haptics.selection();
    setState(() {
      _dragging = true;
      _dragFrom = _frac.value;
      _dragFromY = d.globalPosition.dy;
    });
  }

  void _dragUpdate(DragUpdateDetails d) {
    final s = _scrollable;
    if (!_dragging || s == null || !s.mounted) return;
    final f = (_dragFrom + (d.globalPosition.dy - _dragFromY) / _travel).clamp(
      0.0,
      1.0,
    );
    _frac.value = f;
    final p = s.position;
    if (!p.hasContentDimensions) return;
    p.jumpTo(p.minScrollExtent + f * (p.maxScrollExtent - p.minScrollExtent));
  }

  void _dragEnd() {
    if (_dragging) {
      setState(() => _dragging = false);
      final s = _scrollable;
      if (s != null && s.mounted && s.position.hasContentDimensions) {
        _frac.value = _fracOf(s.position);
      }
    }
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned(
            top: widget.padding.top,
            bottom: widget.padding.bottom,
            right: 0,
            width: _touchW,
            child: LayoutBuilder(
              builder: (context, c) {
                _travel = math.max(0.0, c.maxHeight - _h);
                return AnimatedBuilder(
                  animation: Listenable.merge([_reveal, _frac]),
                  builder: (context, _) {
                    final r = _reveal.value;
                    return Stack(
                      children: [
                        Positioned(
                          top: _frac.value * _travel,
                          left: 0,
                          right: 0,
                          height: _h,
                          child: IgnorePointer(
                            ignoring: r == 0,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              dragStartBehavior: DragStartBehavior.down,
                              onVerticalDragDown: (_) => _hideTimer?.cancel(),
                              onVerticalDragStart: _dragStart,
                              onVerticalDragUpdate: _dragUpdate,
                              onVerticalDragEnd: (_) => _dragEnd(),
                              onVerticalDragCancel: _dragEnd,
                              child: Opacity(
                                opacity: r,
                                child: Transform.translate(
                                  offset: Offset((1 - r) * 12, 0),
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Padding(
                                      padding: const EdgeInsets.only(
                                        right: _right,
                                      ),
                                      child: _thumb(scheme),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(ColorScheme scheme) {
    final fg = _dragging ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return AnimatedContainer(
      duration: Motion.quick,
      width: _w,
      height: _h,
      decoration: BoxDecoration(
        color: _dragging
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(_w / 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .2),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(11, 18),
          painter: _ArrowsPainter(fg),
        ),
      ),
    );
  }
}

/// 上下两个实心小三角。
class _ArrowsPainter extends CustomPainter {
  const _ArrowsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const th = 6.0;
    final arrows = Path()
      ..moveTo(w / 2, 0)
      ..lineTo(w, th)
      ..lineTo(0, th)
      ..close()
      ..moveTo(0, h - th)
      ..lineTo(w, h - th)
      ..lineTo(w / 2, h)
      ..close();
    // 填充再描一圈圆角边,三角尖角不扎眼
    canvas
      ..drawPath(arrows, Paint()..color = color)
      ..drawPath(
        arrows,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(covariant _ArrowsPainter old) => old.color != color;
}
