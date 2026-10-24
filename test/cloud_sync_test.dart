import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:plana_app/core/platform/cloud_folder.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/cloud_sync/cloud_sync_engine.dart';
import 'package:plana_app/features/gallery/models.dart';

/// 普通目录充当同步文件夹;[placeholders] 里的名字模拟「iCloud 还没下载」。
class _DirFolder implements CloudFolder {
  _DirFolder(this.dir);

  final Directory dir;
  final placeholders = <String>{};
  final downloadRequests = <String>[];
  int writes = 0;

  @override
  Future<List<CloudFolderEntry>> list() async => [
    for (final f in dir.listSync().whereType<File>())
      CloudFolderEntry(
        name: f.uri.pathSegments.last,
        size: f.lengthSync(),
        modifiedAt: f.lastModifiedSync().millisecondsSinceEpoch,
        downloaded: !placeholders.contains(f.uri.pathSegments.last),
      ),
  ];

  @override
  Future<Uint8List> read(String name) {
    if (placeholders.contains(name)) throw StateError('$name 还没下载');
    return File('${dir.path}/$name').readAsBytes();
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    writes++;
    await File('${dir.path}/$name').writeAsBytes(bytes);
  }

  @override
  Future<void> requestDownload(Iterable<String> names) async =>
      downloadRequests.addAll(names);

  List<String> get names => [
    for (final e in dir.listSync().whereType<File>()) e.uri.pathSegments.last,
  ]..sort();
}

/// 每次一张内容不同的真 PNG(像素色值随 [seed] 变)。
Uint8List _png(int seed) {
  final image = img.Image(width: 2, height: 2);
  image.setPixelRgb(0, 0, seed & 0xff, (seed >> 8) & 0xff, 7);
  return img.encodePng(image);
}

class _Device {
  _Device(this.root, this.stores, this.engine);

  final Directory root;
  final AppStores stores;
  final CloudSyncEngine engine;

  static Future<_Device> open(Directory root, CloudFolder folder) async {
    final stores = await AppStores.open(rootOverride: root);
    return _Device(
      root,
      stores,
      CloudSyncEngine(
        folder: folder,
        gallery: stores.gallery,
        localGallery: stores.localGallery,
        supportRoot: root,
      ),
    );
  }

  Future<void> generate(String id, Uint8List bytes, int createdAt) async {
    await stores.gallery.persistResult(
      ResultImage(
        id: id,
        width: 2,
        height: 2,
        seed: 1,
        createdAt: createdAt,
        bytes: bytes,
      ),
    );
    await stores.gallery.idle;
  }
}

Future<Directory> _temp(String name) async {
  final dir = await Directory.systemTemp.createTemp(name);
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });
  return dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同步文件名带生成时刻与哈希段,可解析回来', () {
    final t = DateTime(2026, 10, 24, 15, 30, 12).millisecondsSinceEpoch;
    final name = cloudFileName(t, '0123456789abcdef', 'png');
    expect(name, 'Plana_20261024_153012_0123456789abcdef.png');
    expect(cloudHashOf(name), '0123456789abcdef');
    expect(cloudCreatedAtOf(name), t);
    expect(cloudHashOf('my_photo.png'), isNull);
    expect(cloudCreatedAtOf('my_photo.png'), isNull);
    expect(isCloudImageName('a.JPG'), isTrue);
    expect(isCloudImageName('.a.png.icloud'), isFalse);
    expect(isCloudImageName('notes.txt'), isFalse);
  });

  test('原生通道解析状态与文件列表', () {
    final status = parseCloudFolderStatus({
      'configured': true,
      'available': true,
      'name': 'Plana',
    });
    expect(status.ready, isTrue);
    expect(status.name, 'Plana');
    expect(parseCloudFolderStatus(null).configured, isFalse);
    expect(
      parseCloudFolderStatus({'configured': true, 'available': false}).ready,
      isFalse,
    );

    final entries = parseCloudFolderEntries([
      {'name': 'a.png', 'size': 3, 'modified': 9, 'downloaded': false},
      {'name': ''},
      'junk',
      {'name': 'b.png'},
    ]);
    expect(entries.map((e) => e.name), ['a.png', 'b.png']);
    expect(entries.first.downloaded, isFalse);
    expect(entries.first.modifiedAt, 9);
    expect(entries.last.downloaded, isTrue);
  });

  test('上传生成历史与外部导入,第二轮不重复写', () async {
    final folder = _DirFolder(await _temp('plana_cloud_folder'));
    final device = await _Device.open(await _temp('plana_cloud_a'), folder);
    final t = DateTime(2026, 10, 1, 8, 0, 0).millisecondsSinceEpoch;
    await device.generate('gen0', _png(1), t);
    await device.stores.localGallery.importBytes(_png(2), 'photo.png');

    final first = await device.engine.run();
    expect(first.uploaded, 2);
    expect(first.downloaded, 0);
    expect(folder.names, hasLength(2));
    expect(folder.names, contains(startsWith('Plana_20261001_080000_')));

    final second = await device.engine.run();
    expect(second.uploaded, 0);
    expect(second.downloaded, 0);
    expect(folder.writes, 2);
  });

  test('另一台设备拉回图片并还原生成时刻,不会再传回去', () async {
    final folder = _DirFolder(await _temp('plana_cloud_folder'));
    final a = await _Device.open(await _temp('plana_cloud_a'), folder);
    final b = await _Device.open(await _temp('plana_cloud_b'), folder);
    final t = DateTime(2026, 9, 3, 21, 15, 0).millisecondsSinceEpoch;
    await a.generate('gen0', _png(10), t);
    await b.generate('gen0', _png(20), t + 1000);

    await a.engine.run();
    final pulled = await b.engine.run();
    expect(pulled.uploaded, 1);
    expect(pulled.downloaded, 1);
    final imported = b.stores.localGallery.initialItems.singleWhere(
      (item) => !item.isHistoryReference,
    );
    expect(imported.createdAt, t);
    expect(
      await b.stores.localGallery.readImage(imported.id),
      orderedEquals(_png(10)),
    );

    final back = await a.engine.run();
    expect(back.downloaded, 1);
    // 两台各自一张,文件夹里就是两张 —— 拉回来的图没有被再写一份
    expect(folder.names, hasLength(2));
    expect(folder.writes, 2);
    expect((await b.engine.run()).uploaded, 0);
  });

  test('进度按阶段报,每段总数从头到尾不变,没活干的阶段不报', () async {
    final folder = _DirFolder(await _temp('plana_cloud_folder'));
    final a = await _Device.open(await _temp('plana_cloud_a'), folder);
    final b = await _Device.open(await _temp('plana_cloud_b'), folder);
    for (var i = 0; i < 3; i++) {
      await a.generate('gen$i', _png(100 + i), i + 1);
    }
    await a.engine.run();
    await b.generate('gen0', _png(200), 1);
    await b.generate('gen1', _png(201), 2);

    final events = <(CloudSyncPhase, int, int)>[];
    await b.engine.run(
      onProgress: (p, done, total) => events.add((p, done, total)),
    );

    expect(events, [
      (CloudSyncPhase.checking, 0, 0),
      (CloudSyncPhase.uploading, 0, 2),
      (CloudSyncPhase.uploading, 1, 2),
      (CloudSyncPhase.uploading, 2, 2),
      (CloudSyncPhase.pulling, 0, 3),
      (CloudSyncPhase.pulling, 1, 3),
      (CloudSyncPhase.pulling, 2, 3),
      (CloudSyncPhase.pulling, 3, 3),
    ]);

    events.clear();
    await b.engine.run(
      onProgress: (p, done, total) => events.add((p, done, total)),
    );
    expect(events, [(CloudSyncPhase.checking, 0, 0)]);
  });

  test('本机删掉拉回的图不会被再拉回,恢复全部可以找回', () async {
    final folder = _DirFolder(await _temp('plana_cloud_folder'));
    final a = await _Device.open(await _temp('plana_cloud_a'), folder);
    final b = await _Device.open(await _temp('plana_cloud_b'), folder);
    await a.generate('gen0', _png(30), 1);
    await a.engine.run();
    await b.engine.run();
    final imported = b.stores.localGallery.initialItems.single;
    await b.stores.localGallery.delete(imported.id);

    final again = await b.engine.run();
    expect(again.downloaded, 0);
    expect(b.stores.localGallery.initialItems, isEmpty);

    final restored = await b.engine.run(restoreAll: true);
    expect(restored.downloaded, 1);
    expect(b.stores.localGallery.initialItems, hasLength(1));
  });

  test('iCloud 占位先请求下载,下载好后下一轮再拉', () async {
    final folder = _DirFolder(await _temp('plana_cloud_folder'));
    final a = await _Device.open(await _temp('plana_cloud_a'), folder);
    final b = await _Device.open(await _temp('plana_cloud_b'), folder);
    await a.generate('gen0', _png(40), 1);
    await a.engine.run();
    final name = folder.names.single;
    folder.placeholders.add(name);

    final waiting = await b.engine.run();
    expect(waiting.waiting, 1);
    expect(waiting.failed, 0);
    expect(folder.downloadRequests, [name]);
    expect(b.stores.localGallery.initialItems, isEmpty);

    folder.placeholders.clear();
    final done = await b.engine.run();
    expect(done.downloaded, 1);
  });

  test('关掉拉取就是单向备份;账本重启后仍有效', () async {
    final folder = _DirFolder(await _temp('plana_cloud_folder'));
    final a = await _Device.open(await _temp('plana_cloud_a'), folder);
    final rootB = await _temp('plana_cloud_b');
    final b = await _Device.open(rootB, folder);
    await a.generate('gen0', _png(50), 1);
    await b.generate('gen0', _png(60), 2);
    await a.engine.run();

    final backupOnly = await b.engine.run(pull: false);
    expect(backupOnly.uploaded, 1);
    expect(backupOnly.downloaded, 0);
    expect(
      b.stores.localGallery.initialItems.where((i) => !i.isHistoryReference),
      isEmpty,
    );

    final reopened = await _Device.open(rootB, folder);
    final next = await reopened.engine.run();
    expect(next.uploaded, 0);
    expect(next.downloaded, 1);
    expect(folder.writes, 2);
  });

  test('换文件夹后账本作废,同内容按哈希认出不重写', () async {
    final folder = _DirFolder(await _temp('plana_cloud_folder'));
    final device = await _Device.open(await _temp('plana_cloud_a'), folder);
    await device.generate('gen0', _png(70), 1);
    await device.engine.run();
    await device.engine.reset();

    final rerun = await device.engine.run();
    expect(rerun.uploaded, 0);
    expect(rerun.downloaded, 0);
    expect(folder.writes, 1);
  });
}
