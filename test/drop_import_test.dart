import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/drop_import.dart';

void main() {
  test('拖入图片通道保留原始字节和文件名', () {
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    final image = parseDroppedImage({
      'bytes': bytes,
      'name': 'source.image.png',
    });

    expect(image, isNotNull);
    expect(image!.bytes, same(bytes));
    expect(image.fileName, 'source.image.png');
    expect(image.displayName, 'source.image');
  });

  test('拖入图片通道拒绝空字节并为缺失名称兜底', () {
    expect(
      parseDroppedImage({'bytes': Uint8List(0), 'name': 'empty.png'}),
      isNull,
    );
    final image = parseDroppedImage({
      'bytes': Uint8List.fromList([1]),
      'name': ' ',
    });
    expect(image?.fileName, 'dropped_image.png');
  });
}
