import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/gallery/gallery_store.dart';
import '../../features/generate/workspace_store.dart';
import 'blob_store.dart';
import 'cache_sweep.dart';

/// 应用级持久化门面:main() 启动时 [open](读工作台存档 + 图库索引),
/// 经 [appStoresProvider] 注入;各 Notifier 从这里水合初始状态、
/// 往这里排队落盘。任何一环载入失败都按「首启空档」降级,不 brick 启动。
class AppStores {
  AppStores._(this.blobs, this.workspace, this.gallery);

  final BlobStore blobs;
  final WorkspaceStore workspace;
  final GalleryStore gallery;

  /// 测试用空档:临时目录、不读盘;写入尽力而为。
  factory AppStores.ephemeral() {
    final root = Directory.systemTemp.createTempSync('plana_stores');
    final blobs = BlobStore(root);
    return AppStores._(
      blobs,
      WorkspaceStore(blobs, root),
      GalleryStore(blobs, root),
    );
  }

  /// [rootOverride]:测试指定根目录(生产走平台 support 目录)。
  static Future<AppStores> open({Directory? rootOverride}) async {
    Directory root;
    if (rootOverride != null) {
      root = rootOverride;
    } else {
      try {
        root = await getApplicationSupportDirectory();
      } catch (_) {
        root = Directory.systemTemp; // 拿不到目录的极端兜底:本次会话内存态可用
      }
    }
    final blobs = BlobStore(root);
    final workspace = WorkspaceStore(blobs, root);
    final gallery = GalleryStore(blobs, root);
    try {
      await blobs.ensureReady();
    } catch (_) {}
    await workspace.load();
    await gallery.load();
    return AppStores._(blobs, workspace, gallery);
  }

  /// 退后台/失焦即刻把防抖窗口里的挂起状态落盘(进程被杀不丢)。
  void flushNow() {
    workspace.flush();
    gallery.flushIndex();
  }

  /// 启动后台维护(避开首帧,延迟几秒):清选图器缓存垃圾 + blob GC。
  void postBootMaintenance() {
    Future<void>(() async {
      await Future<void>.delayed(const Duration(seconds: 6));
      await sweepPickerCache();
      try {
        final live = <String>{
          ...await workspace.liveRefs(),
          ...await gallery.liveRefs(),
        };
        await blobs.gc(live);
      } catch (_) {}
    });
  }
}

final appStoresProvider = Provider<AppStores>(
  (_) => throw StateError('AppStores 未注入:main() 需 overrideWithValue'),
);
