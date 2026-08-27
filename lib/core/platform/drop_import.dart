import 'package:flutter/services.dart';

const dropImportChannelName = 'plana/drop_import';

enum DropImportState { idle, hover, loading }

DropImportState parseDropImportState(Object? value) => switch (value) {
  'hover' => DropImportState.hover,
  'loading' => DropImportState.loading,
  _ => DropImportState.idle,
};

/// 从 iPad 外部拖入的原始图片。字节不经过 UIImage 重编码,可保留 PNG 元数据。
class DroppedImage {
  const DroppedImage({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;

  String get displayName => fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
}

/// 解码原生拖放通道的数据。保持独立函数,便于钉住平台契约。
DroppedImage? parseDroppedImage(Object? arguments) {
  if (arguments is! Map<Object?, Object?>) return null;
  final bytes = arguments['bytes'];
  if (bytes is! Uint8List || bytes.isEmpty) return null;
  final rawName = arguments['name'];
  final name = rawName is String && rawName.trim().isNotEmpty
      ? rawName.trim()
      : 'dropped_image.png';
  return DroppedImage(bytes: bytes, fileName: name);
}

class DropImportBridge {
  DropImportBridge({
    this._channel = const MethodChannel(dropImportChannelName),
  });

  final MethodChannel _channel;

  void attach(
    Future<void> Function(DroppedImage image) onImage, {
    void Function(DropImportState state)? onStateChanged,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'dropState':
          onStateChanged?.call(parseDropImportState(call.arguments));
          return;
        case 'importImage':
          final image = parseDroppedImage(call.arguments);
          if (image != null) await onImage(image);
          return;
      }
    });
  }

  void detach() => _channel.setMethodCallHandler(null);
}
