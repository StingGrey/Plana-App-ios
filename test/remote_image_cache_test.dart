import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/remote_image.dart';

Uint8List _bytes(int n, {int fill = 7}) =>
    Uint8List.fromList(List.filled(n, fill));

void main() {
  late Directory root;
  late Directory dir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_imgcache');
    dir = Directory('${root.path}/img_cache');
    RemoteImageStore.bind(root);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  List<File> files() => dir.listSync().whereType<File>().toList();

  /// 按内容首字节找回落盘文件(文件名是 URL 哈希,测试里拿不到)。
  File fileWithFill(int fill) => files().firstWhere(
    (f) => f.readAsBytesSync().firstOrNull == fill,
    orElse: () => throw StateError('没找到 fill=$fill 的缓存文件'),
  );

  test('写入后按 URL 读回;不同 URL 互不串味', () async {
    await RemoteImageStore.write('https://x/a.png', _bytes(16, fill: 1));
    await RemoteImageStore.write('https://x/b.png', _bytes(16, fill: 2));
    expect((await RemoteImageStore.read('https://x/a.png'))!.first, 1);
    expect((await RemoteImageStore.read('https://x/b.png'))!.first, 2);
    expect(await RemoteImageStore.read('https://x/never.png'), isNull);
  });

  test('URL 哈希成文件名:带查询串/非 ASCII 也不炸文件系统', () async {
    const url = 'https://x/图 片.png?w=200&sig=a/b+c';
    await RemoteImageStore.write(url, _bytes(8));
    expect(await RemoteImageStore.read(url), hasLength(8));
    // 落盘名只有十六进制:原 URL 里的 / ? & 空格一个都没漏进路径
    final names = files().map((f) => f.uri.pathSegments.last).toList();
    expect(names, hasLength(1));
    expect(names.single, matches(RegExp(r'^[0-9a-f]{40}$')));
  });

  test('原子写:不留 .tmp 残渣', () async {
    await RemoteImageStore.write('https://x/a', _bytes(32));
    expect(files().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('trim 按 mtime 从旧到新删到达标', () async {
    for (var i = 0; i < 5; i++) {
      await RemoteImageStore.write('https://x/$i', _bytes(1000, fill: i));
    }
    for (var i = 0; i < 5; i++) {
      fileWithFill(i).setLastModifiedSync(DateTime(2026, 1, 1 + i)); // 越小越旧
    }

    await RemoteImageStore.trim(limit: 2500);

    // 5000 字节要压到 ≤2500:删掉最旧的三个,留最新的两个
    final left = files();
    expect(left, hasLength(2));
    expect({for (final f in left) f.readAsBytesSync().first}, {3, 4});
  });

  test('trim 不超上限时一个都不删', () async {
    await RemoteImageStore.write('https://x/a', _bytes(100));
    await RemoteImageStore.trim(limit: 1 << 20);
    expect(files(), hasLength(1));
  });

  test('目录不可用时整层降级为空,读写清理都不抛', () async {
    // 绑到一个不可建的路径(父目录是文件),模拟拿不到 support 目录的极端情况
    final blocker = File('${root.path}/blocker')..writeAsStringSync('x');
    RemoteImageStore.bind(Directory(blocker.path));
    expect(await RemoteImageStore.read('https://x/a'), isNull);
    await RemoteImageStore.write('https://x/a', _bytes(8)); // 吞掉写失败
    await RemoteImageStore.trim();
  });
}
