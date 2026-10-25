// 翻页吸附:抬手速度接得上、停在页上、不冲过头。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/smooth_page_physics.dart';

void main() {
  ScrollMetrics at(double pixels) => FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 4000,
    pixels: pixels,
    viewportDimension: 400,
    axisDirection: AxisDirection.right,
    devicePixelRatio: 1,
  );

  test('抬手速度接着走,停在下一页,中途不超过目标', () {
    final sim = const SmoothPagePhysics().createBallisticSimulation(
      at(500),
      1200,
    )!;
    expect(sim.dx(0), closeTo(1200, 1));
    var t = 0.0;
    while (!sim.isDone(t)) {
      expect(sim.x(t), lessThanOrEqualTo(800.5));
      t += 1 / 120;
    }
    expect(sim.x(t), closeTo(800, .5));
  });

  test('慢慢放手没过半页:回到原页', () {
    final sim = const SmoothPagePhysics().createBallisticSimulation(
      at(520),
      0,
    )!;
    expect(sim.x(10), closeTo(400, .5));
  });
}
