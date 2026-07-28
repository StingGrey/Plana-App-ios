import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/import/image_metadata.dart';

/// 覆写→读取端解析、清除→读取端归零的回环:写入端位序对不对,由
/// app 自己的 stealth 读取端说了算。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> makePng(int w, int h) {
    final rnd = Random(42);
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = rnd.nextInt(256);
      rgba[i + 1] = rnd.nextInt(256);
      rgba[i + 2] = rnd.nextInt(256);
      rgba[i + 3] = 255;
    }
    return encodePngFromRgba(rgba, w, h);
  }

  test('覆写元数据 → 自家读取端可解析出提示词', () async {
    final base = await makePng(160, 160);
    expect(await extractImageMetadata(base), isNull); // 干净底图

    final written = await writeCustomMetadataPng(base, '1girl, plana, smile');
    final meta = await extractImageMetadata(written);
    expect(meta, isNotNull);
    expect(meta!.sourceType, ImageSourceType.novelai);
    expect(meta.prompt, '1girl, plana, smile');
    expect(meta.width, 160);
  });

  test('清除:带隐写的图清完读不出元数据', () async {
    final written = await writeCustomMetadataPng(
      await makePng(160, 160),
      'secret prompt',
    );
    final cleaned = await cleanImagePng(written);
    expect(await extractImageMetadata(cleaned), isNull);
  });

  test('图太小放不下时明确报错', () async {
    final tiny = await makePng(16, 16);
    expect(() => writeCustomMetadataPng(tiny, 'x'), throwsA(isA<StateError>()));
  });
}
