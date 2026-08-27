/// PNGPKG 兼容的 Gilbert 曲线图片混淆 / 解混淆。
///
/// 算法参考 https://github.com/KeyMove/PNGPKG （MIT）：先用广义 Hilbert
/// 曲线遍历全部像素，再沿曲线循环平移指定距离。解混淆使用完全相反的映射。
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry, compute;
import 'package:image/image.dart' as img;

const double _goldenConjugate = 0.6180339887498949;

const _pngPkgLicense = '''
MIT License

Copyright (c) 2026 KeyMove

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
''';

/// 将算法上游的 MIT 声明加入“关于 → 第三方许可”。
void registerPngPkgLicense() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['PNGPKG'], _pngPkgLicense);
  });
}

/// PNGPKG 百分比滑杆对应的实际像素偏移。
///
/// 上游把 62% 作为“黄金分割”快捷值，使用四舍五入；其它百分比使用向下取整。
int pngPkgOffsetForPercent(int pixelCount, int percent) {
  if (pixelCount <= 0) return 0;
  final normalized = percent.clamp(0, 100);
  if (normalized == 62) return (_goldenConjugate * pixelCount).round();
  return (normalized / 100 * pixelCount).floor();
}

/// 在后台 isolate 中处理图片并输出 PNG 字节，避免大图阻塞界面。
Future<Uint8List> transformPngPkgImage(
  Uint8List source, {
  required int offset,
  required bool decrypt,
}) => compute(_transformEncoded, (source, offset, decrypt));

Uint8List _transformEncoded((Uint8List, int, bool) request) {
  final (source, offset, decrypt) = request;
  final decoded = img.decodeImage(source);
  if (decoded == null) throw StateError('图片解码失败');

  final rgba = decoded.getBytes(order: img.ChannelOrder.rgba);
  final transformed = transformPngPkgRgba(
    rgba,
    width: decoded.width,
    height: decoded.height,
    offset: offset,
    decrypt: decrypt,
  );
  final output = img.Image.fromBytes(
    width: decoded.width,
    height: decoded.height,
    bytes: transformed.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodePng(output));
}

/// 对 RGBA 像素执行 PNGPKG 的正向或逆向置换。
///
/// 独立暴露纯像素函数，便于验证算法的可逆性和跨实现兼容性。
Uint8List transformPngPkgRgba(
  Uint8List rgba, {
  required int width,
  required int height,
  required int offset,
  required bool decrypt,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('图片尺寸必须大于 0');
  }
  final total = width * height;
  if (rgba.length != total * 4) {
    throw ArgumentError.value(rgba.length, 'rgba', 'RGBA 字节数与图片尺寸不匹配');
  }

  final curve = pngPkgGilbertCurve(width, height);
  final shift = ((offset % total) + total) % total;
  final output = Uint8List(rgba.length);
  for (var i = 0; i < total; i++) {
    final originalPixel = curve[i];
    final shiftedPixel = curve[(i + shift) % total];
    final sourcePixel = decrypt ? shiftedPixel : originalPixel;
    final targetPixel = decrypt ? originalPixel : shiftedPixel;
    final sourceByte = sourcePixel * 4;
    final targetByte = targetPixel * 4;
    output[targetByte] = rgba[sourceByte];
    output[targetByte + 1] = rgba[sourceByte + 1];
    output[targetByte + 2] = rgba[sourceByte + 2];
    output[targetByte + 3] = rgba[sourceByte + 3];
  }
  return output;
}

/// 生成与 PNGPKG `gilbert2d` 相同的像素索引路径。
Int32List pngPkgGilbertCurve(int width, int height) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('曲线尺寸必须大于 0');
  }
  final curve = Int32List(width * height);
  var cursor = 0;

  void generate(int x, int y, int ax, int ay, int bx, int by) {
    final w = (ax + ay).abs();
    final h = (bx + by).abs();
    final dax = ax.sign;
    final day = ay.sign;
    final dbx = bx.sign;
    final dby = by.sign;

    if (h == 1) {
      for (var i = 0; i < w; i++) {
        curve[cursor++] = x + y * width;
        x += dax;
        y += day;
      }
      return;
    }
    if (w == 1) {
      for (var i = 0; i < h; i++) {
        curve[cursor++] = x + y * width;
        x += dbx;
        y += dby;
      }
      return;
    }

    // JavaScript 的 Math.floor 对负数向 -∞ 取整；Dart 的 ~/ 则向 0 取整。
    // 曲线递归后半段会出现负向量，必须显式复刻 Math.floor(n / 2)。
    var ax2 = _floorHalf(ax);
    var ay2 = _floorHalf(ay);
    var bx2 = _floorHalf(bx);
    var by2 = _floorHalf(by);

    if (2 * w > 3 * h) {
      if ((ax2 + ay2).abs().isOdd && w > 2) {
        ax2 += dax;
        ay2 += day;
      }
      generate(x, y, ax2, ay2, bx, by);
      generate(x + ax2, y + ay2, ax - ax2, ay - ay2, bx, by);
    } else {
      if ((bx2 + by2).abs().isOdd && h > 2) {
        bx2 += dbx;
        by2 += dby;
      }
      generate(x, y, bx2, by2, ax2, ay2);
      generate(x + bx2, y + by2, ax, ay, bx - bx2, by - by2);
      generate(
        x + (ax - dax) + (bx2 - dbx),
        y + (ay - day) + (by2 - dby),
        -bx2,
        -by2,
        -(ax - ax2),
        -(ay - ay2),
      );
    }
  }

  if (width >= height) {
    generate(0, 0, width, 0, 0, height);
  } else {
    generate(0, 0, 0, height, width, 0);
  }
  if (cursor != curve.length) {
    throw StateError('Gilbert 曲线未覆盖全部像素');
  }
  return curve;
}

int _floorHalf(int value) => value >= 0 ? value ~/ 2 : -((-value + 1) ~/ 2);
