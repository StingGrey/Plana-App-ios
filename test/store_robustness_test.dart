import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';

/// 1×1 透明 PNG(最小合法字节,充当图库里的历史结果图)。
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// 审计 §1C 的存档健壮性回归。
///
/// `persistence_test.dart` 已覆盖「损坏存档不 brick 启动」,但那条用的是**空**
/// 图库目录,所以从未走到真正危险的分支:索引坏了、而原图还在盘上。
/// 本文件补的就是这一格。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 造一个「有 3 张历史图 + 索引损坏」的图库目录。
  Directory corruptedGalleryWithImages() {
    final root = Directory.systemTemp.createTempSync('plana_gallery_corrupt');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final id in ['gen0', 'gen1', 'gen2']) {
      File('${root.path}/gallery/images/$id.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png);
    }
    File('${root.path}/gallery/index.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"v":1,"seq":3,"items":[{"id":"gen0"'); // 半截 JSON
    return root;
  }

  test('索引损坏但原图还在:不得把发号器归零(否则新图覆盖老图)', () async {
    final root = corruptedGalleryWithImages();
    final stores = await AppStores.open(rootOverride: root);

    // 这是 S1C-01 的要害:seq 归零 → 下一张写 gen0.png → 覆盖盘上仍在的 gen0.png,
    // 老作品彻底丢失,事后修好索引也回不来。
    expect(
      stores.gallery.seq,
      greaterThan(2),
      reason: '盘上已有 gen0/1/2,发号器必须避开它们',
    );
  });

  test('索引损坏但原图还在:应从目录重建条目,而非当作空库', () async {
    final root = corruptedGalleryWithImages();
    final stores = await AppStores.open(rootOverride: root);

    // vibe_library / char_library 都有目录重建兜底,图库应当对齐。
    expect(
      stores.gallery.initialResults.map((r) => r.id),
      containsAll(['gen0', 'gen1', 'gen2']),
    );
  });

  test('索引损坏且目录为空:仍按空库降级,不崩(既有行为,防回归)', () async {
    final root = Directory.systemTemp.createTempSync('plana_gallery_empty');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/gallery/index.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{oops');

    final stores = await AppStores.open(rootOverride: root);
    expect(stores.gallery.initialResults, isEmpty);
  });
}
