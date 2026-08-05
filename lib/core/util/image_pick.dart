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

/// [pickImagesOrFiles] 的结果:图库与文件浏览器二选一,同一次只有一支非空。
class PickedSources {
  const PickedSources.images(this.images) : files = const [];

  const PickedSources.files(this.files) : images = const [];

  const PickedSources.none() : images = const [], files = const [];

  /// 从应用内图库选的图,字节已读好。
  final List<PickedImage> images;

  /// 从系统文件浏览器选的文件,字节未读(见 `file_read.dart`)。
  final List<PlatformFile> files;

  bool get isEmpty => images.isEmpty && files.isEmpty;
}

/// 同 [pickImageFiles],但「从文件选」那支**不限扩展名**:图片之外的内容
/// (如 .naiv4vibe / .naiv4vibebundle)也挑得到,由调用方按内容自行分流。
/// 扩展名过滤在 Android 上会把这类自定义后缀直接挡住(没有对应 MIME),
/// 顺带也会漏掉文件管理器认不出 MIME 的图。
///
/// 文件那支不预读字节:整包 vibe 可能上百 MB(图是 base64),`withData` 会把
/// 整批堆进内存;交调用方按 `file_read.dart` 流式读。
Future<PickedSources> pickImagesOrFiles(BuildContext context) async {
  if (Platform.isAndroid) {
    final out = await _gallery(context, multiple: true);
    if (out == null) return const PickedSources.none();
    if (!out.useFileBrowser) return PickedSources.images(await _readAssets(out));
    // 用户点了「从文件选」→ 落到下方系统文件浏览器
  }
  final res = await FilePicker.platform.pickFiles(
    type: FileType.any,
    allowMultiple: true,
  );
  return PickedSources.files(res?.files ?? const []);
}

// 文件对话框的扩展名过滤(桌面端与 Android 兜底共用)。
const _imageExts = ['png', 'jpg', 'jpeg', 'webp', 'gif'];

Future<List<PickedImage>> _pick(
  BuildContext context, {
  required bool multiple,
}) async {
  if (Platform.isAndroid) {
    final out = await _gallery(context, multiple: multiple);
    if (out == null) return const [];
    if (!out.useFileBrowser) return _readAssets(out);
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

/// 应用内图库选择器,返回 null = 用户取消。
Future<GalleryPickOutcome?> _gallery(
  BuildContext context, {
  required bool multiple,
}) => Navigator.of(context).push<GalleryPickOutcome>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => GalleryPickerPage(multiple: multiple),
  ),
);

/// 图库资产 → 原文件字节(PNG 元数据原样保留)。
Future<List<PickedImage>> _readAssets(GalleryPickOutcome out) async {
  final picked = <PickedImage>[];
  for (final a in out.assets) {
    final bytes = await a.originBytes;
    if (bytes == null || bytes.isEmpty) continue;
    final name = await a.titleAsync;
    picked.add(PickedImage(name.isEmpty ? 'image' : name, bytes));
  }
  return picked;
}
