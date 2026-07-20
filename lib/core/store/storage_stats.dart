import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 存储管理的目录扫描:各功能位置的占用与条目数。
/// 纯文件系统视角,不碰业务 provider——扫描不加载任何库。
class StorageCategory {
  const StorageCategory({required this.key, required this.bytes, this.count});

  final String key;
  final int bytes;

  /// 条目数(图库张数/blob 个数/编码条数…);不适用为 null。
  final int? count;
}

class StorageReport {
  const StorageReport({
    required this.totalBytes,
    required this.categories,
    required this.otherBytes,
  });

  /// 应用数据总占用(支持目录 + 缓存 + 文档;不含安装包本体)。
  final int totalBytes;
  final List<StorageCategory> categories;

  /// 未归类部分(debug 资产解压/系统杂项/零散配置)。
  final int otherBytes;

  StorageCategory? operator [](String key) {
    for (final c in categories) {
      if (c.key == key) return c;
    }
    return null;
  }
}

Future<int> _sizeOf(FileSystemEntity ent) async {
  try {
    if (ent is File) {
      return await ent.exists() ? await ent.length() : 0;
    }
    if (ent is Directory) {
      if (!await ent.exists()) return 0;
      var sum = 0;
      await for (final e in ent.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            sum += await e.length();
          } catch (_) {}
        }
      }
      return sum;
    }
  } catch (_) {}
  return 0;
}

Future<int?> _countIn(Directory d, {String? suffix}) async {
  try {
    if (!await d.exists()) return 0;
    var n = 0;
    await for (final e in d.list(followLinks: false)) {
      if (suffix == null || e.path.endsWith(suffix)) n++;
    }
    return n;
  } catch (_) {
    return null;
  }
}

/// 全量扫描。key 清单:gallery / blobs / vibeLib / vibeEnc / charLib /
/// lexicon / models / temp。
Future<StorageReport> scanStorage() async {
  final sup = await getApplicationSupportDirectory();
  final tmp = await getTemporaryDirectory();
  Directory? docs;
  try {
    docs = await getApplicationDocumentsDirectory();
  } catch (_) {}

  Directory sub(String p) => Directory('${sup.path}/$p');

  // 超分模型:支持目录顶层的 .bin/.param(缺失时下次超分从 assets 重解包)
  var modelBytes = 0;
  var modelCount = 0;
  try {
    await for (final e in sup.list(followLinks: false)) {
      if (e is File &&
          (e.path.endsWith('.bin') || e.path.endsWith('.param'))) {
        try {
          modelBytes += await e.length();
          modelCount++;
        } catch (_) {}
      }
    }
  } catch (_) {}

  final categories = <StorageCategory>[
    StorageCategory(
      key: 'gallery',
      bytes: await _sizeOf(sub('gallery')),
      count: await _countIn(Directory('${sup.path}/gallery/images'),
          suffix: '.png'),
    ),
    StorageCategory(
      key: 'blobs',
      bytes: await _sizeOf(sub('blobs')),
      count: await _countIn(sub('blobs')),
    ),
    StorageCategory(
      key: 'vibeLib',
      bytes: await _sizeOf(sub('vibe_library')),
      count: await _countIn(Directory('${sup.path}/vibe_library/files')),
    ),
    StorageCategory(
      key: 'vibeEnc',
      bytes: await _sizeOf(sub('vibe_encodings')),
      count: await _countIn(sub('vibe_encodings'), suffix: '.enc'),
    ),
    StorageCategory(
      key: 'charLib',
      bytes: await _sizeOf(sub('charref_library')),
      count: await _countIn(Directory('${sup.path}/charref_library/files')),
    ),
    StorageCategory(
      key: 'lexicon',
      bytes: await _sizeOf(File('${sup.path}/role_tag_mapping.json')),
    ),
    StorageCategory(key: 'models', bytes: modelBytes, count: modelCount),
    StorageCategory(
      key: 'temp',
      bytes: await _sizeOf(tmp),
      count: await _countIn(tmp),
    ),
  ];

  final total = await _sizeOf(sup) +
      await _sizeOf(tmp) +
      (docs == null ? 0 : await _sizeOf(docs));
  var categorized = 0;
  for (final c in categories) {
    categorized += c.bytes;
  }
  return StorageReport(
    totalBytes: total,
    categories: categories,
    otherBytes: (total - categorized).clamp(0, total),
  );
}

/// 清除超分模型解包缓存(下次超分自动从 assets 重新解包,无损)。
Future<void> clearUpscaleModels() async {
  try {
    final sup = await getApplicationSupportDirectory();
    await for (final e in sup.list(followLinks: false)) {
      if (e is File &&
          (e.path.endsWith('.bin') || e.path.endsWith('.param'))) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  } catch (_) {}
}

/// 人读字节格式(1.2 GB / 34.5 MB / 890 KB / 12 B)。
String fmtBytes(int bytes) {
  if (bytes >= 1 << 30) {
    return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1 << 20) {
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1 << 10) {
    return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}
