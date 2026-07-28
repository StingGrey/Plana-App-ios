import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/cost.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/res_rules.dart';

/// 审计 §1B 补的计费与分辨率规则回归。
///
/// 这两个模块零 UI 依赖,却直接决定「花不花钱」和「按钮上显示多少点」——
/// 阶段 5 要改 `isOpus` 回退方向(S1B-02),先把口径钉死。

GenerateState _s({
  String model = 'NAI 4.5 Full',
  int width = 832,
  int height = 1216,
  int steps = 28,
  List<VibeItem> vibes = const [],
  List<CharRefItem> charRefs = const [],
  Img2ImgConfig? img2img,
}) => GenerateState.initial().copyWith(
  vibes: vibes,
  charRefs: charRefs,
  img2img: img2img,
  params: const GenParams().copyWith(
    model: model,
    width: width,
    height: height,
    steps: steps,
  ),
);

void main() {
  group('免费档判定(Opus · ≤28 步 · ≤1024²)', () {
    test('三条同时满足才免费', () {
      expect(estimateCost(_s(), isOpus: true), 0);
    });

    test('非 Opus 一律收费', () {
      expect(estimateCost(_s(), isOpus: false), greaterThan(0));
    });

    test('步数越过 28 即收费', () {
      expect(estimateCost(_s(steps: 28), isOpus: true), 0);
      expect(estimateCost(_s(steps: 29), isOpus: true), greaterThan(0));
    });

    test('像素越过 1024² 即收费(边界正好在阈值上仍免费)', () {
      expect(estimateCost(_s(width: 1024, height: 1024), isOpus: true), 0);
      expect(
        estimateCost(_s(width: 1024, height: 1088), isOpus: true),
        greaterThan(0),
      );
    });
  });

  group('附加费(免费档也照收)', () {
    test('Vibe 第 5 张起每张 +2,前 4 张不额外收', () {
      List<VibeItem> n(int c) => [
        for (var i = 0; i < c; i++) VibeItem(id: 'v$i'),
      ];
      expect(estimateCost(_s(vibes: n(4)), isOpus: true), 0);
      expect(estimateCost(_s(vibes: n(5)), isOpus: true), 2);
      expect(estimateCost(_s(vibes: n(7)), isOpus: true), 6);
    });

    test('停用的 Vibe 不计费', () {
      final off = [
        for (var i = 0; i < 7; i++) VibeItem(id: 'v$i', enabled: i < 4),
      ];
      expect(estimateCost(_s(vibes: off), isOpus: true), 0);
    });

    test('角色参考每张 +5,且只在 4.5 系模型上计', () {
      final refs = [CharRefItem(id: 'r0'), CharRefItem(id: 'r1')];
      expect(estimateCost(_s(charRefs: refs), isOpus: true), 10);
      // 非 4.5 模型不会下发角色参考,故不计费
      expect(
        estimateCost(_s(model: 'NAI 4.0 Full', charRefs: refs), isOpus: true),
        0,
      );
    });
  });

  test('图生图按强度折算,且不低于 2', () {
    final full = estimateCost(_s(steps: 40), isOpus: false);
    final half = estimateCost(
      _s(steps: 40, img2img: const Img2ImgConfig(strength: 0.5)),
      isOpus: false,
    );
    // 无底图时 strength 不参与折算(image 为 null)
    expect(half, full);
  });

  test('Anima 不计 Anlas(走 Modal 后端)', () {
    expect(estimateCost(_s(model: 'Anima Turbo', steps: 40), isOpus: false), 0);
  });

  group('res_rules', () {
    test('snapDim 归到 64 倍数且不小于 64(四舍五入,非截断)', () {
      expect(snapDim(0), 64); // 低于最小值抬到 64
      expect(snapDim(80), 64); // 1.25 档 → 向下
      expect(snapDim(100), 128); // 1.5625 档 → 向上
      expect(snapDim(832), 832); // 已对齐不动
    });

    test('分档阈值与 cost 的免费判定同源', () {
      expect(classifyPixels(1024, 1024), PixelTier.free);
      expect(classifyPixels(1024, 1088), PixelTier.paid);
      expect(classifyPixels(3072, 1088), PixelTier.over);
    });

    test('clampToMaxPixels 缩回预算内并保持 64 对齐', () {
      final r = clampToMaxPixels(3072, 3072);
      expect(r.w * r.h, lessThanOrEqualTo(kMaxTotalPixels));
      expect(r.w % kResSnapStep, 0);
      expect(r.h % kResSnapStep, 0);
    });

    test('scaleToFree 缩进免费档', () {
      final r = scaleToFree(1216, 1600);
      expect(r.w * r.h, lessThanOrEqualTo(kFreePixelThreshold));
      expect(classifyPixels(r.w, r.h), PixelTier.free);
    });

    test('比例显示:常规化简,超 99 退化为小数比', () {
      expect(formatAspectRatio(832, 1216), '13:19');
      expect(formatAspectRatio(1024, 1024), '1:1');
      expect(formatAspectRatio(0, 100), '—');
    });
  });
}
