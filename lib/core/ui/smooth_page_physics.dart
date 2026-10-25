import 'package:flutter/widgets.dart';

/// 翻页吸附:抬手后从**抬手那一刻的速度**接着走,匀匀地减到停在页上,不像默认
/// 弹簧那样被拉一下猛地加速。配 `PageView(pageSnapping: false)` 用 —— 开着
/// pageSnapping 的话 PageView 会在外面再套一层自带的吸附,这里的就不生效了。
class SmoothPagePhysics extends ScrollPhysics {
  const SmoothPagePhysics({super.parent});

  @override
  SmoothPagePhysics applyTo(ScrollPhysics? ancestor) =>
      SmoothPagePhysics(parent: buildParent(ancestor));

  double _targetPixels(ScrollMetrics p, Tolerance t, double v) {
    final size = p.viewportDimension;
    if (size <= 0) return p.pixels;
    var page = p.pixels / size;
    if (v < -t.velocity) {
      page -= .5;
    } else if (v > t.velocity) {
      page += .5;
    }
    return (page.roundToDouble() * size).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final v = velocity;
    // 拖出边界的回弹交给上层
    if ((v <= 0 && position.pixels <= position.minScrollExtent) ||
        (v >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, v);
    }
    final t = toleranceFor(position);
    final target = _targetPixels(position, t, v);
    if ((target - position.pixels).abs() < t.distance) return null;
    return _EaseToSimulation(
      from: position.pixels,
      to: target,
      velocity: v,
      tolerance: t,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}

/// 从 [from] 以初速 [velocity] 出发、到 [to] 时速度归零的三次曲线。
/// 时长按「照这个初速匀减速走完」估,太快太慢都夹住;初速大到会冲过头时压一点。
class _EaseToSimulation extends Simulation {
  _EaseToSimulation({
    required this.from,
    required this.to,
    required double velocity,
    required super.tolerance,
  }) {
    final d = (to - from).abs();
    final toward = (to - from).sign;
    final speed = velocity * toward; // 朝目标方向的分量
    _duration = speed > 1
        ? (2 * d / speed).clamp(.16, .38)
        : .3; // 慢放手或反方向:给一个固定节奏
    // 冲过头的条件:朝目标初速 × 时长 > 3 × 距离;反方向时 > 距离就会先往回甩一大截
    final cap = (speed >= 0 ? 3 : 1) * d / _duration;
    _v0 = toward * speed.clamp(-cap, cap);
  }

  final double from;
  final double to;
  late final double _duration;
  late final double _v0;

  double _s(double t) => (t / _duration).clamp(0.0, 1.0);

  @override
  double x(double time) {
    final s = _s(time);
    final s2 = s * s, s3 = s2 * s;
    return (2 * s3 - 3 * s2 + 1) * from +
        (s3 - 2 * s2 + s) * _duration * _v0 +
        (-2 * s3 + 3 * s2) * to;
  }

  @override
  double dx(double time) {
    if (time >= _duration) return 0;
    final s = _s(time);
    final s2 = s * s;
    return ((6 * s2 - 6 * s) * from +
            (3 * s2 - 4 * s + 1) * _duration * _v0 +
            (-6 * s2 + 6 * s) * to) /
        _duration;
  }

  @override
  bool isDone(double time) => time >= _duration;
}
