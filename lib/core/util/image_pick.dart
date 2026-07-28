import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../ui/gallery_picker_page.dart';

/// 选中的图片:文件名 + 原始字节。
class PickedImage {
  const PickedImage(this.name, this.bytes);

  final String name;
  final Uint8List bytes;

  /// 去扩展名(入库命名/展示用)。
  String get baseName => name.replaceAll(RegExp(r'\.[^.]+$'), '');
}

/// 选单张图片,取消返回 null。
///
/// Android:应用内图库选择器(直读媒体库,全部相册可达;系统照片选择器
/// 只放行固定分类且不看 app 权限,故不用),右上角可改走系统文件浏览器
/// 兜底(媒体库没收录的图也能选)。桌面端:原生文件对话框。
Future<PickedImage?> pickImageFile(BuildContext context) async {
  final list = await _pick(context, multiple: false);
  return list.isEmpty ? null : list.first;
}

/// 选多张图片,取消/空选返回空列表。
Future<List<PickedImage>> pickImageFiles(BuildContext context) =>
    _pick(context, multiple: true);

// 文件对话框的扩展名过滤(桌面端与 Android 兜底共用)。
const _imageExts = ['png', 'jpg', 'jpeg', 'webp', 'gif'];

Future<List<PickedImage>> _pick(
  BuildContext context, {
  required bool multiple,
}) async {
  if (Platform.isAndroid) {
    final out = await Navigator.of(context).push<GalleryPickOutcome>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => GalleryPickerPage(multiple: multiple),
      ),
    );
    if (out == null) return const [];
    if (!out.useFileBrowser) {
      final picked = <PickedImage>[];
      for (final a in out.assets) {
        final bytes = await a.originBytes; // 原文件字节,PNG 元数据原样保留
        if (bytes == null || bytes.isEmpty) continue;
        final name = await a.titleAsync;
        picked.add(PickedImage(name.isEmpty ? 'image' : name, bytes));
      }
      return picked;
    }
    // 用户点了「从文件选」→ 落到下方系统文件浏览器
  }
  final res = await FilePicker.platform.pickFiles(
    type: FileType.custom, // custom 走 OPEN_DOCUMENT;image 会被送去照片选择器
    allowedExtensions: _imageExts,
    allowMultiple: multiple,
    withData: true,
    compressionQuality: 0, // 禁止重压缩:PNG 里的生成参数元数据必须原样保留
  );
  return [
    for (final f in res?.files ?? const <PlatformFile>[])
      if (f.bytes case final b? when b.isNotEmpty) PickedImage(f.name, b),
  ];
}
