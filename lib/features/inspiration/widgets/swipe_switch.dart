import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 左右滑动切换:正文跟手平移,松手过了门槛(四分之一屏宽或甩得够快)就滑出去、
/// 调 [onStep] 换成相邻那页,新内容从另一侧滑进来;没过门槛弹回。
/// 两头没有下一页时只给一点阻尼位移。
class SwipeSwitch extends StatefulWidget {
  const SwipeSwitch({
    super.key,
    required this.child,
    required this.canPrev,
    required this.canNext,
    required this.onStep,
  });

  final Widget child;
  final bool canPrev;
  final bool canNext;

  /// -1 = 上一页,1 = 下一页。
  final ValueChanged<int> onStep;

  @override
  State<SwipeSwitch> createState() => _SwipeSwitchState();
}

class _SwipeSwitchState extends State<SwipeSwitch>
    with SingleTickerProviderStateMixin {
  /// 平移量,按宽度算的比例(-1 ~ 1)。
  late final _offset = AnimationController.unbounded(vsync: this);
  double _width = 1;
  bool _busy = false;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  Future<void> _to(double v, Duration d) =>
      _offset.animateTo(v, duration: d, curve: Motion.standard);

  void _update(DragUpdateDetails d) {
    if (_busy) return;
    var v = _offset.value + d.primaryDelta! / _width;
    // 往没有页的一头拖:阻尼
    if ((v > 0 && !widget.canPrev) || (v < 0 && !widget.canNext)) {
      v = _offset.value + d.primaryDelta! / _width * .25;
      v = v.clamp(-.08, .08);
    }
    _offset.value = v.clamp(-1.0, 1.0);
  }

  Future<void> _end(DragEndDetails d) async {
    if (_busy) return;
    final v = _offset.value;
    final speed = d.primaryVelocity ?? 0;
    final dir = v.abs() > .25 || speed.abs() > 600
        ? (speed.abs() > 600 ? -speed.sign : -v.sign).toInt()
        : 0;
    final ok = (dir == 1 && widget.canNext) || (dir == -1 && widget.canPrev);
    if (!ok) {
      await _to(0, Motion.fast);
      return;
    }
    _busy = true;
    await _to(-dir.toDouble(), Motion.fast);
    if (!mounted) return;
    widget.onStep(dir);
    _offset.value = dir.toDouble();
    await _to(0, Motion.medium);
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _width = c.maxWidth <= 0 ? 1 : c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: _update,
          onHorizontalDragEnd: _end,
          onHorizontalDragCancel: () => _to(0, Motion.fast),
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _offset,
              builder: (context, child) => FractionalTranslation(
                translation: Offset(_offset.value, 0),
                child: child,
              ),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
