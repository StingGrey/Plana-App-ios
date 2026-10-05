// 「已存进相册」标记:打上之后要进索引,重启读回来还在;没存过的不占键。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';

/// 1×1 PNG,够走完落盘/读回这一整程。
final _png = Uint8List.fromList(const [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
  0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, //
  13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);

Future<void> _until(Future<bool> Function() cond) async {
  for (var i = 0; i < 200; i++) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('等待条件超时');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('已保存标记落盘,重启读回', () async {
    final root = await Directory.systemTemp.createTemp('plana_saved');
    addTearDown(() async {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });

    final stores1 = await AppStores.open(rootOverride: root);
    final c1 = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores1)],
    );
    addTearDown(c1.dispose);

    final gal = c1.read(galleryProvider.notifier);
    final a = gal.addResult(bytes: _png, width: 8, height: 8, seed: 1);
    final b = gal.addResult(bytes: _png, width: 8, height: 8, seed: 2);
    expect(a.saved, isFalse);

    gal.markSaved([a.id]);
    final now = {for (final r in c1.read(galleryProvider).results) r.id: r};
    expect(now[a.id]!.saved, isTrue);
    expect(now[a.id]!.bytes, isNotNull, reason: '打标不能把内存里的字节丢掉');
    expect(now[b.id]!.saved, isFalse);

    stores1.flushNow();
    final indexFile = File('${root.path}/gallery/index.json');
    await _until(
      () async =>
          await indexFile.exists() &&
          (await indexFile.readAsString()).contains('"sv"'),
    );

    final stores2 = await AppStores.open(rootOverride: root);
    final back = {for (final r in stores2.gallery.initialResults) r.id: r};
    expect(back[a.id]!.saved, isTrue);
    expect(back[b.id]!.saved, isFalse);
  });
}
