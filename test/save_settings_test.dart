import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/gallery/save_pipeline.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/import/image_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('保存设置 json 回环 + 脏数据回退', () {
    const s = SaveSettings(
      meta: SaveMeta.custom,
      format: SaveFormat.jpg,
      quality: 0.5,
      customPrompt: '1girl',
    );
    expect(SaveSettings.fromJson(s.toJson()), s);
    expect(SaveSettings.fromJson({}), const SaveSettings());
    expect(
      SaveSettings.fromJson({'meta': 'nope', 'quality': 99}).quality,
      1.0,
    );
    expect(SaveSettings.fromJson({'meta': 'nope'}).meta, SaveMeta.original);
  });

  test('保存管线:PNG 原样直出;JPG 重编码为无 alpha 的 JPEG', () async {
    final rgba = Uint8List(64 * 64 * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 200;
      rgba[i + 1] = 120;
      rgba[i + 2] = 40;
      rgba[i + 3] = 255;
    }
    final png = await encodePngFromRgba(rgba, 64, 64);

    final original =
        await processForSave(png, const SaveSettings());
    expect(identical(original, png), isTrue); // 原始 = 零拷贝直出

    final jpg = await processForSave(
      png,
      const SaveSettings(format: SaveFormat.jpg, quality: 0.8),
    );
    final decoded = img.decodeJpg(jpg);
    expect(decoded, isNotNull);
    expect(decoded!.width, 64);
  });

  test('保存管线:PNG+覆写可被读取端解析,PNG+清除读不出', () async {
    final rgba = Uint8List(160 * 160 * 4);
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255;
    }
    final png = await encodePngFromRgba(rgba, 160, 160);

    final custom = await processForSave(
      png,
      const SaveSettings(meta: SaveMeta.custom, customPrompt: 'plana, smile'),
    );
    final meta = await extractImageMetadata(custom);
    expect(meta?.prompt, 'plana, smile');

    final clean = await processForSave(
      custom,
      const SaveSettings(meta: SaveMeta.clean),
    );
    expect(await extractImageMetadata(clean), isNull);
  });
}
