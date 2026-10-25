import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 左右滑动切换:正文跟手平移(最多挪 [_travel] 屏宽,边挪边淡),松手过了门槛
/// (约八分之一屏宽或轻甩)就淡出、调 [onStep] 换成相邻那页,新内容从另一侧短距
/// 滑进来;没过门槛弹回。
/// 两头没有下一页时只给一点阻尼位移。[progress] 报出往相邻页的进度
/// (正 = 往后一页,给顶栏页签跟手);换完页、新内容滑进来时报 0。
class SwipeSwitch extends StatefulWidget {
  const SwipeSwitch({
    super.key,
    required this.child,
    required this.canPrev,
    required this.canNext,
    required this.onStep,
    this.progress,
  });

  final Widget child;
  final bool canPrev;
  final bool canNext;

  /// -1 = 上一页,1 = 下一页。
  final ValueChanged<int> onStep;
  final ValueNotifier<double>? progress;

  @override
  State<SwipeSwitch> createState() => _SwipeSwitchState();
}

class _SwipeSwitchState extends State<SwipeSwitch>
    with SingleTickerProviderStateMixin {
  /// 平移量,按宽度算的比例(-1 ~ 1)。
  late final AnimationController _offset =
      AnimationController.unbounded(vsync: this)..addListener(() {
        if (!_entering) {
          widget.progress?.value = (-_offset.value / _travel).clamp(-1.0, 1.0);
        }
      });

  /// 换完页、新内容正在滑进来。
  bool _entering = false;

  /// 正文最多挪出去的距离(屏宽比例);换页的进出都只走这一小段。
  static const _travel = .3;

  /// 过了这个距离(屏宽比例)或这个甩速(px/s)就换页。
  static const _commit = .12;
  static const _fling = 300.0;

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
      v = v.clamp(-.05, .05);
    }
    _offset.value = v.clamp(-_travel, _travel);
  }

  Future<void> _end(DragEndDetails d) async {
    if (_busy) return;
    final v = _offset.value;
    final speed = d.primaryVelocity ?? 0;
    final dir = speed.abs() > _fling
        ? -speed.sign.toInt()
        : v.abs() > _commit
        ? -v.sign.toInt()
        : 0;
    final ok = (dir == 1 && widget.canNext) || (dir == -1 && widget.canPrev);
    if (!ok) {
      await _to(0, Motion.fast);
      return;
    }
    _busy = true;
    await _to(-dir * _travel, Motion.fast);
    if (!mounted) return;
    widget.onStep(dir);
    _entering = true;
    widget.progress?.value = 0;
    _offset.value = dir * _travel;
    await _to(0, Motion.fast);
    _entering = false;
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
              builder: (context, child) => Opacity(
                opacity: (1 - _offset.value.abs() / _travel * .85).clamp(
                  0.0,
                  1.0,
                ),
                child: FractionalTranslation(
                  translation: Offset(_offset.value, 0),
                  child: child,
                ),
              ),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
