import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/util/image_scramble.dart';

void main() {
  group('PNGPKG Gilbert 曲线', () {
    test('小尺寸路径与上游 JavaScript 实现逐项一致', () {
      expect(pngPkgGilbertCurve(3, 2), [0, 3, 4, 5, 2, 1]);
      expect(pngPkgGilbertCurve(2, 3), [0, 1, 3, 5, 4, 2]);
      expect(pngPkgGilbertCurve(5, 4), [
        0,
        1,
        6,
        5,
        10,
        15,
        16,
        11,
        12,
        17,
        18,
        19,
        14,
        13,
        9,
        8,
        7,
        2,
        3,
        4,
      ]);
    });

    test('覆盖全部像素且相邻节点保持四邻接', () {
      for (final size in [(1, 1), (4, 3), (3, 7), (8, 5), (9, 9)]) {
        final (width, height) = size;
        final curve = pngPkgGilbertCurve(width, height);
        expect(curve.toSet().length, width * height);
        expect(curve.every((p) => p >= 0 && p < width * height), isTrue);
        for (var i = 1; i < curve.length; i++) {
          final previous = curve[i - 1];
          final current = curve[i];
          final dx = (previous % width - current % width).abs();
          final dy = (previous ~/ width - current ~/ width).abs();
          expect(dx + dy, 1, reason: '$width×$height 路径在 $i 处不连续');
        }
      }
    });
  });

  group('PNGPKG 像素置换', () {
    test('正向映射与上游实现一致', () {
      final source = _indexedRgba(6);
      final encrypted = transformPngPkgRgba(
        source,
        width: 3,
        height: 2,
        offset: 2,
        decrypt: false,
      );
      expect(_redChannels(encrypted), [2, 5, 4, 1, 0, 3]);
    });

    test('任意尺寸与偏移都能无损解混淆', () {
      for (final size in [(1, 1), (2, 3), (5, 4), (7, 9)]) {
        final (width, height) = size;
        final source = _indexedRgba(width * height);
        for (final offset in [
          0,
          1,
          3,
          width * height - 1,
          width * height + 5,
        ]) {
          final encrypted = transformPngPkgRgba(
            source,
            width: width,
            height: height,
            offset: offset,
            decrypt: false,
          );
          final restored = transformPngPkgRgba(
            encrypted,
            width: width,
            height: height,
            offset: offset,
            decrypt: true,
          );
          expect(restored, source, reason: '$width×$height, offset=$offset');
        }
      }
    });

    test('编码图片可在后台 isolate 完整往返为 PNG', () async {
      final sourceRgba = _indexedRgba(12);
      final sourceImage = img.Image.fromBytes(
        width: 4,
        height: 3,
        bytes: sourceRgba.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      final sourcePng = Uint8List.fromList(img.encodePng(sourceImage));
      final encrypted = await transformPngPkgImage(
        sourcePng,
        offset: 7,
        decrypt: false,
      );
      final restored = await transformPngPkgImage(
        encrypted,
        offset: 7,
        decrypt: true,
      );
      final decoded = img.decodePng(restored);
      expect(decoded, isNotNull);
      expect(decoded!.getBytes(order: img.ChannelOrder.rgba), sourceRgba);
    });

    test('62% 使用黄金分割，其它比例向下取整', () {
      expect(pngPkgOffsetForPercent(6, 62), 4);
      expect(pngPkgOffsetForPercent(100, 62), 62);
      expect(pngPkgOffsetForPercent(7, 50), 3);
      expect(pngPkgOffsetForPercent(7, -10), 0);
      expect(pngPkgOffsetForPercent(7, 110), 7);
    });
  });
}

Uint8List _indexedRgba(int pixels) => Uint8List.fromList([
  for (var i = 0; i < pixels; i++) ...[i, 255 - i, i * 3 % 256, 255],
]);

List<int> _redChannels(Uint8List rgba) => [
  for (var i = 0; i < rgba.length; i += 4) rgba[i],
];
