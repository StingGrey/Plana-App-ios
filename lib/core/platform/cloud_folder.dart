import 'package:flutter/services.dart';

const cloudFolderChannelName = 'plana/cloud_folder';

/// 同步文件夹的状态。[configured] 但不 [available]:书签还在,文件夹却被删 /
/// 改名 / iCloud 退出登录了 —— 界面要提示重新选,而不是当成「从没选过」。
class CloudFolderStatus {
  const CloudFolderStatus({
    this.configured = false,
    this.available = false,
    this.name,
  });

  final bool configured;
  final bool available;
  final String? name;

  bool get ready => configured && available;
}

/// 文件夹里的一个文件。[downloaded] 为 false:iCloud 只同步了占位,字节还在
/// 云端,读之前要先 [CloudFolder.requestDownload],等系统拉下来。
class CloudFolderEntry {
  const CloudFolderEntry({
    required this.name,
    this.size = 0,
    this.modifiedAt = 0,
    this.downloaded = true,
  });

  final String name;
  final int size;
  final int modifiedAt;
  final bool downloaded;
}

/// 解码原生通道的数据。保持独立函数,便于钉住平台契约。
CloudFolderStatus parseCloudFolderStatus(Object? value) {
  if (value is! Map<Object?, Object?>) return const CloudFolderStatus();
  final name = value['name'];
  return CloudFolderStatus(
    configured: value['configured'] == true,
    available: value['available'] == true,
    name: name is String && name.isNotEmpty ? name : null,
  );
}

List<CloudFolderEntry> parseCloudFolderEntries(Object? value) {
  if (value is! List) return const [];
  return [
    for (final raw in value)
      if (raw is Map<Object?, Object?> &&
          raw['name'] is String &&
          (raw['name'] as String).isNotEmpty)
        CloudFolderEntry(
          name: raw['name'] as String,
          size: (raw['size'] as num?)?.toInt() ?? 0,
          modifiedAt: (raw['modified'] as num?)?.toInt() ?? 0,
          downloaded: raw['downloaded'] != false,
        ),
  ];
}

/// 同步引擎只认这个接口:生产走原生通道,测试换成普通目录。
abstract class CloudFolder {
  Future<List<CloudFolderEntry>> list();
  Future<Uint8List> read(String name);
  Future<void> write(String name, Uint8List bytes);
  Future<void> requestDownload(Iterable<String> names);
}

/// iOS 原生实现见 tool/ios/SceneDelegate.swift 的 CloudFolderBridge。
class CloudFolderChannel implements CloudFolder {
  CloudFolderChannel({
    this._channel = const MethodChannel(cloudFolderChannelName),
  });

  final MethodChannel _channel;

  Future<CloudFolderStatus> status() async =>
      parseCloudFolderStatus(await _channel.invokeMethod<Object?>('status'));

  /// 弹系统文件夹选择器。取消返回 null。
  Future<CloudFolderStatus?> pick() async {
    final value = await _channel.invokeMethod<Object?>('pick');
    return value == null ? null : parseCloudFolderStatus(value);
  }

  /// 只忘掉书签,文件夹里的文件原样保留。
  Future<void> clear() => _channel.invokeMethod<void>('clear');

  @override
  Future<List<CloudFolderEntry>> list() async =>
      parseCloudFolderEntries(await _channel.invokeMethod<Object?>('list'));

  @override
  Future<Uint8List> read(String name) async {
    final bytes = await _channel.invokeMethod<Uint8List>('read', {
      'name': name,
    });
    if (bytes == null) {
      throw PlatformException(code: 'io', message: '读取 $name 失败');
    }
    return bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) =>
      _channel.invokeMethod<void>('write', {'name': name, 'bytes': bytes});

  @override
  Future<void> requestDownload(Iterable<String> names) {
    final list = names.toList();
    if (list.isEmpty) return Future.value();
    return _channel.invokeMethod<void>('download', {'names': list});
  }
}
