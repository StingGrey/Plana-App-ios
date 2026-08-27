import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

/// 生成系统相册里使用的真实文件名。
///
/// [Gal.putImageBytes] 在 Android 会按字节自动补扩展名,但 iOS 会把传入的
/// `name` 原样写成 `originalFilename`,因此会出现无后缀图片。这里统一改走
/// 带扩展名的临时文件,两端都由文件路径得到一致的名字。
String galleryImageFileName(String name, String extension) {
  final ext = extension.trim().replaceFirst(RegExp(r'^\.+'), '').toLowerCase();
  if (!RegExp(r'^[a-z0-9]+$').hasMatch(ext)) {
    throw ArgumentError.value(extension, 'extension', '无效的文件扩展名');
  }
  var base = name.trim().replaceAll(RegExp(r'[/\\\u0000-\u001f]'), '_');
  base = base.replaceFirst(
    RegExp(r'\.(?:png|jpe?g)$', caseSensitive: false),
    '',
  );
  if (base.isEmpty || base == '.' || base == '..') base = 'image';
  return '$base.$ext';
}

/// 把图片字节以带格式后缀的文件名保存到系统相册。
Future<void> saveImageBytesToGallery(
  Uint8List bytes, {
  required String name,
  required String extension,
  String? album,
}) async {
  final temp = await getTemporaryDirectory();
  final jobDir = await temp.createTemp('plana_gallery_');
  try {
    final file = File(
      '${jobDir.path}/${galleryImageFileName(name, extension)}',
    );
    await file.writeAsBytes(bytes, flush: true);
    await Gal.putImage(file.path, album: album);
  } finally {
    try {
      await jobDir.delete(recursive: true);
    } on FileSystemException {
      // 相册已完成导入;临时目录清理失败不应把一次成功保存改判为失败。
    }
  }
}
