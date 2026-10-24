import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_dates.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';

/// 1×1 透明 PNG。
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Directory _tempRoot(String name) {
  final root = Directory.systemTemp.createTempSync(name);
  addTearDown(() async {
    for (var i = 0; i < 10; i++) {
      try {
        root.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  return root;
}

ProviderContainer _container(AppStores stores) {
  final c = ProviderContainer(
    overrides: [appStoresProvider.overrideWithValue(stores)],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle(AppStores stores) async {
  stores.flushNow();
  await stores.gallery.idle;
  await stores.albums.idle;
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('恢复:插回原位,相册归属与收藏原样回来', () async {
    final root = _tempRoot('plana_trash_restore');
    final stores = await AppStores.open(rootOverride: root);
    final c = _container(stores);
    final gal = c.read(galleryProvider.notifier);
    final albums = c.read(albumsProvider.notifier);
    final ids = [
      for (var i = 0; i < 4; i++)
        gal.addResult(bytes: _png, width: 8, height: 8, seed: i).id,
    ];
    final trip = await albums.create('旅行');
    await albums.organize({ids[1]}, {trip});
    await albums.setFavorite(ids[1], true);
    await albums.setCover(trip, ids[1]);

    gal.deleteResults([ids[1]]);
    gal.deleteResults([ids[2]]);
    expect(
      [for (final r in c.read(galleryProvider).results) r.id],
      [ids[3], ids[0]],
    );
    // 新删的在前
    expect(
      [for (final t in c.read(galleryProvider).trash) t.image.id],
      [ids[2], ids[1]],
    );
    // 删了不在任何相册里显示,归属仍记着
    final view = c.read(albumsProvider);
    expect(view.ofImage(ids[1]), {trip, favoritesId});

    expect(gal.restoreTrash([ids[1], ids[2]]), 2);
    expect(
      [for (final r in c.read(galleryProvider).results) r.id],
      [ids[3], ids[2], ids[1], ids[0]],
    );
    expect(c.read(galleryProvider).trash, isEmpty);
    final back = c.read(albumsProvider);
    expect(back.contains(trip, ids[1]), isTrue);
    expect(back.isFavorite(ids[1]), isTrue);
    expect(back.cover(trip)?.sourceImageId, ids[1]);
    // 不在回收站里的不算
    expect(gal.restoreTrash([ids[0]]), 0);
  });

  test('回收站随索引落盘,重启后归属还在,彻底删除才清归属和文件', () async {
    final root = _tempRoot('plana_trash_persist');
    final stores = await AppStores.open(rootOverride: root);
    final c = _container(stores);
    final gal = c.read(galleryProvider.notifier);
    final albums = c.read(albumsProvider.notifier);
    final a = gal.addResult(bytes: _png, width: 8, height: 8, seed: 1);
    final b = gal.addResult(bytes: _png, width: 8, height: 8, seed: 2);
    final trip = await albums.create('旅行');
    await albums.organize({a.id, b.id}, {trip});
    gal.deleteResults([a.id, b.id]);
    final deletedAt = c.read(galleryProvider).trash.first.deletedAt;
    await _settle(stores);

    final stores2 = await AppStores.open(rootOverride: root);
    expect(stores2.gallery.initialResults, isEmpty);
    expect(
      [for (final t in stores2.gallery.initialTrash) t.image.id],
      [b.id, a.id],
    );
    expect(stores2.gallery.initialTrash.first.deletedAt, deletedAt);
    expect(stores2.albums.data.contains(trip, a.id), isTrue);

    final c2 = _container(stores2);
    final gal2 = c2.read(galleryProvider.notifier);
    c2.read(albumsProvider);
    gal2.purgeTrash([a.id]);
    expect(
      [for (final t in c2.read(galleryProvider).trash) t.image.id],
      [b.id],
    );
    await _settle(stores2);
    expect(File('${root.path}/gallery/images/${a.id}.png').existsSync(), false);
    expect(File('${root.path}/gallery/images/${b.id}.png').existsSync(), true);
    expect(c2.read(albumsProvider).ofImage(a.id), isEmpty);
    expect(c2.read(albumsProvider).contains(trip, b.id), isTrue);
  });

  test('超过保留天数的启动时彻底删除', () async {
    final root = _tempRoot('plana_trash_expire');
    final stores = await AppStores.open(rootOverride: root);
    final c = _container(stores);
    final gal = c.read(galleryProvider.notifier);
    final old = gal.addResult(bytes: _png, width: 8, height: 8, seed: 1);
    final fresh = gal.addResult(bytes: _png, width: 8, height: 8, seed: 2);
    gal.deleteResults([old.id, fresh.id]);
    await _settle(stores);

    // 把 old 的删除时刻改到保留期之前
    final index = File('${root.path}/gallery/index.json');
    final j = jsonDecode(index.readAsStringSync()) as Map<String, dynamic>;
    final expired = DateTime.now()
        .subtract(const Duration(days: kTrashKeepDays))
        .millisecondsSinceEpoch;
    for (final e in j['trash'] as List) {
      if ((e as Map)['id'] == old.id) e['dt'] = expired;
    }
    index.writeAsStringSync(jsonEncode(j));

    final stores2 = await AppStores.open(rootOverride: root);
    final c2 = _container(stores2);
    c2.read(galleryProvider);
    await Future<void>.delayed(Duration.zero);
    expect(
      [for (final t in c2.read(galleryProvider).trash) t.image.id],
      [fresh.id],
    );
    await _settle(stores2);
    expect(
      File('${root.path}/gallery/images/${old.id}.png').existsSync(),
      false,
    );
  });

  test('隔了几个自然日', () {
    final now = DateTime(2026, 10, 24, 0, 5);
    expect(
      galleryDaysSince(
        DateTime(2026, 10, 23, 23, 55).millisecondsSinceEpoch,
        now,
      ),
      1,
    );
    expect(
      galleryDaysSince(
        DateTime(2026, 10, 24, 0, 1).millisecondsSinceEpoch,
        now,
      ),
      0,
    );
    expect(
      galleryDaysSince(DateTime(2026, 9, 24, 12).millisecondsSinceEpoch, now),
      30,
    );
  });
}
