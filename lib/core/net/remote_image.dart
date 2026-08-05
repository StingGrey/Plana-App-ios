import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../store/atomic_file.dart';

/// 远端图片的磁盘缓存(`<support>/img_cache/<sha1(url)>`)。
///
/// **为什么必须自己做**:Flutter 的 `Image.network` 走 `NetworkImage` →
/// dart:io `HttpClient`,而 `HttpClient` **没有 HTTP 缓存实现** —— 响应头里的
/// `Cache-Control` / `ETag` 一概不生效。唯一的缓存是 `PaintingBinding.imageCache`
/// (内存,默认 1000 张 / 100 MiB,存的还是**解码后位图**),杀进程即空。
/// 结果就是:每次冷启动重下全部缩略图、来回滚动反复重下、离线完全不可用。
///
/// 目录由 [bind] 在 `AppStores.open()` 里挂上。用静态量而不是 provider,是因为
/// [RemoteImageProvider] 是 `ImageProvider`,拿不到 `ref`(同 `Haptics.enabled`)。
/// 没挂上时整层降级为「直连不缓存」,不影响功能。
abstract final class RemoteImageStore {
  static Directory? _dir;

  /// 磁盘缓存上限;超出时 [trim] 删最久未用的(启动后台维护里跑一次)。
  static const maxBytes = 128 << 20;

  /// 命中后回写 mtime 的最小间隔 —— 滚动列表每帧都 touch 一次太浪费,
  /// 天级粒度足够把「常看的」和「一年没碰的」区分开。
  static const _touchAfter = Duration(days: 1);

  static void bind(Directory supportRoot) =>
      _dir = Directory('${supportRoot.path}/img_cache');

  static File? _fileOf(String url) {
    final d = _dir;
    if (d == null) return null;
    return File('${d.path}/${sha1.convert(utf8.encode(url))}');
  }

  static Future<Uint8List?> read(String url) async {
    final f = _fileOf(url);
    if (f == null) return null;
    try {
      final st = await f.stat();
      if (st.type == FileSystemEntityType.notFound) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      if (DateTime.now().difference(st.modified) > _touchAfter) {
        unawaited(_touch(f));
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 原子写:文件名是 **URL** 的哈希而非内容的,半截文件没法自证损坏,
  /// 会被后续 [read] 当成有效缓存直接喂给解码器。
  static Future<void> write(String url, Uint8List bytes) async {
    final f = _fileOf(url);
    if (f == null) return;
    try {
      await writeBytesAtomic(f, bytes);
    } catch (_) {}
  }

  static Future<void> _touch(File f) async {
    try {
      await f.setLastModified(DateTime.now());
    } catch (_) {}
  }

  /// 超出 [limit] 时按 mtime 从旧到新删到达标。
  static Future<void> trim({int limit = maxBytes}) async {
    final d = _dir;
    if (d == null) return;
    try {
      if (!await d.exists()) return;
      final files = <({File f, int size, DateTime at})>[];
      var total = 0;
      await for (final ent in d.list(followLinks: false)) {
        if (ent is! File) continue;
        try {
          final st = await ent.stat();
          files.add((f: ent, size: st.size, at: st.modified));
          total += st.size;
        } catch (_) {}
      }
      if (total <= limit) return;
      files.sort((a, b) => a.at.compareTo(b.at));
      for (final e in files) {
        if (total <= limit) break;
        try {
          await e.f.delete();
          total -= e.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 清空(存储管理用)。删掉只是下次要重下,不丢任何用户数据。
  static Future<void> clear() async {
    final d = _dir;
    if (d == null) return;
    try {
      if (!await d.exists()) return;
      await for (final ent in d.list(followLinks: false)) {
        if (ent is File) {
          try {
            await ent.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    // 内存层也要一起倒,否则刚清完的图还在屏幕上挂着,数字对不上观感
    PaintingBinding.instance.imageCache.clear();
  }
}

/// 带磁盘缓存的网络图 provider。行为对齐 `NetworkImage`:同 URL 相等、
/// 走 `imageCache` 内存层、加载失败把自己从内存缓存里踢掉(否则错误态被缓存,
/// 网络恢复了也不会重试)。
@immutable
class RemoteImageProvider extends ImageProvider<RemoteImageProvider> {
  const RemoteImageProvider(this.url, {this.scale = 1.0});

  final String url;
  final double scale;

  static final _client = http.Client();
  static const _timeout = Duration(seconds: 30);

  @override
  Future<RemoteImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<RemoteImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    RemoteImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode, chunks),
      chunkEvents: chunks.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => [ErrorDescription('URL: ${key.url}')],
    );
  }

  Future<ui.Codec> _load(
    RemoteImageProvider key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    try {
      final hit = await RemoteImageStore.read(key.url);
      if (hit != null) {
        return decode(await ui.ImmutableBuffer.fromUint8List(hit));
      }
      final bytes = await _download(key.url, chunks).timeout(_timeout);
      // 落盘是旁路:写失败只是下次还得重下,不该连累这一次显示
      unawaited(RemoteImageStore.write(key.url, bytes));
      return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      // 与 NetworkImage 同款:微任务里踢缓存,让下次 build 能真的重试
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      unawaited(chunks.close());
    }
  }

  static Future<Uint8List> _download(
    String url,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    final uri = Uri.parse(url);
    final resp = await _client.send(http.Request('GET', uri));
    if (resp.statusCode != 200) {
      throw NetworkImageLoadException(statusCode: resp.statusCode, uri: uri);
    }
    final total = resp.contentLength;
    final buf = BytesBuilder(copy: false);
    await for (final part in resp.stream) {
      buf.add(part);
      if (!chunks.isClosed) {
        chunks.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: buf.length,
            expectedTotalBytes: total,
          ),
        );
      }
    }
    final bytes = buf.takeBytes();
    if (bytes.isEmpty) throw Exception('空响应');
    return bytes;
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteImageProvider && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => 'RemoteImageProvider("$url")';
}

/// `Image.network` 的替代:磁盘缓存 + 按布局宽限制解码尺寸。
///
/// **解码尺寸为什么要限**:`imageCache` 存的是解码后位图,一张 1216×1824 就是
/// 8.9 MB,100 MiB 的默认上限只装得下 11 张 —— 网格一滚就雪崩式互相驱逐、
/// 反复重下。默认取布局约束宽 × dpr 作为解码宽(约束无界时不限,交给调用方给
/// [decodeWidth]),缩略图按格子大小解码,同样的内存能多装一个数量级。
class RemoteImage extends StatelessWidget {
  const RemoteImage(
    this.url, {
    super.key,
    this.fit,
    this.width,
    this.height,
    this.decodeWidth,
    this.gaplessPlayback = false,
    this.frameBuilder,
    this.loadingBuilder,
    this.errorBuilder,
  });

  final String url;
  final BoxFit? fit;
  final double? width;
  final double? height;

  /// 解码宽度上限(**逻辑像素**,内部乘 dpr);null = 取布局约束宽。
  final double? decodeWidth;

  final bool gaplessPlayback;
  final ImageFrameBuilder? frameBuilder;
  final ImageLoadingBuilder? loadingBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;

  Widget _image(int? cacheWidth) {
    final base = RemoteImageProvider(url);
    return Image(
      image: cacheWidth == null
          ? base
          : ResizeImage(base, width: cacheWidth, policy: ResizeImagePolicy.fit),
      fit: fit,
      width: width,
      height: height,
      gaplessPlayback: gaplessPlayback,
      frameBuilder: frameBuilder,
      loadingBuilder: loadingBuilder,
      errorBuilder: errorBuilder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    int? px(double logical) {
      final n = (logical * dpr).round();
      return n >= 1 ? n : null;
    }

    final explicit = decodeWidth ?? width;
    if (explicit != null && explicit.isFinite) return _image(px(explicit));
    return LayoutBuilder(
      builder: (context, c) =>
          _image(c.hasBoundedWidth ? px(c.maxWidth) : null),
    );
  }
}
