import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/platform/cloud_folder.dart';
import '../../core/platform/platform_support.dart';
import '../../core/store/app_stores.dart';
import '../../core/util/log.dart';
import '../gallery/gallery_state.dart';
import '../local_gallery/local_gallery_state.dart';
import 'cloud_sync_engine.dart';

const Object _unset = Object();
const _prefsKey = 'cloud_sync_settings';

class CloudSyncSettings {
  const CloudSyncSettings({this.auto = true, this.pull = true});

  /// 出新图、回到前台时自动同步。
  final bool auto;

  /// 把文件夹里其他设备传上来的图导入本地图库。关掉就是单向备份。
  final bool pull;

  CloudSyncSettings copyWith({bool? auto, bool? pull}) =>
      CloudSyncSettings(auto: auto ?? this.auto, pull: pull ?? this.pull);

  factory CloudSyncSettings.fromJson(Map<String, dynamic> j) =>
      CloudSyncSettings(auto: j['auto'] != false, pull: j['pull'] != false);

  Map<String, dynamic> toJson() => {'auto': auto, 'pull': pull};
}

class CloudSyncState {
  const CloudSyncState({
    this.supported = false,
    this.folder,
    this.settings = const CloudSyncSettings(),
    this.running = false,
    this.phase = CloudSyncPhase.checking,
    this.done = 0,
    this.total = 0,
    this.lastSyncAt = 0,
    this.lastReport,
    this.error,
  });

  /// 只有 iOS 有原生文件夹桥(见 tool/ios/SceneDelegate.swift)。
  final bool supported;

  /// null = 还在读书签。
  final CloudFolderStatus? folder;
  final CloudSyncSettings settings;
  final bool running;

  /// 只在 [running] 时有意义;[done] / [total] 是这一阶段内的计数。
  final CloudSyncPhase phase;
  final int done;
  final int total;
  final int lastSyncAt;
  final CloudSyncReport? lastReport;
  final String? error;

  CloudSyncState copyWith({
    Object? folder = _unset,
    CloudSyncSettings? settings,
    bool? running,
    CloudSyncPhase? phase,
    int? done,
    int? total,
    int? lastSyncAt,
    Object? lastReport = _unset,
    Object? error = _unset,
  }) => CloudSyncState(
    supported: supported,
    folder: folder == _unset ? this.folder : folder as CloudFolderStatus?,
    settings: settings ?? this.settings,
    running: running ?? this.running,
    phase: phase ?? this.phase,
    done: done ?? this.done,
    total: total ?? this.total,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lastReport: lastReport == _unset
        ? this.lastReport
        : lastReport as CloudSyncReport?,
    error: error == _unset ? this.error : error as String?,
  );
}

final cloudSyncProvider = NotifierProvider<CloudSyncNotifier, CloudSyncState>(
  CloudSyncNotifier.new,
);

class CloudSyncNotifier extends Notifier<CloudSyncState> {
  final _channel = CloudFolderChannel();
  CloudSyncEngine? _engine;
  Timer? _autoTimer;
  Timer? _waitTimer;
  int _waitRounds = 0;
  bool _again = false;

  @override
  CloudSyncState build() {
    if (!isIOSPlatform) return const CloudSyncState();
    ref.listen<GalleryState>(galleryProvider, (prev, next) {
      if (prev == null) return;
      final before = {for (final r in prev.results) r.id};
      if (next.results.any((r) => !before.contains(r.id))) {
        // 连续出图时攒一攒,不必每张都单独过一遍文件夹
        _scheduleAuto(const Duration(seconds: 5));
      }
    });
    final lifecycle = AppLifecycleListener(
      onResume: () {
        final since = DateTime.now().millisecondsSinceEpoch - state.lastSyncAt;
        if (since > 60 * 1000) _scheduleAuto(const Duration(seconds: 2));
      },
    );
    ref.onDispose(() {
      _autoTimer?.cancel();
      _waitTimer?.cancel();
      lifecycle.dispose();
    });
    Future.microtask(() async {
      await refreshStatus();
      // 避开启动高峰:图库水合、blob GC 都在头几秒
      _scheduleAuto(const Duration(seconds: 8));
    });
    return CloudSyncState(supported: true, settings: _readSettings());
  }

  CloudSyncSettings _readSettings() {
    try {
      final raw = ref.read(prefsStoreProvider).get(_prefsKey);
      if (raw == null || raw.isEmpty) return const CloudSyncSettings();
      return CloudSyncSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return const CloudSyncSettings();
    }
  }

  Future<void> _patchSettings(
    CloudSyncSettings Function(CloudSyncSettings) change,
  ) async {
    final next = change(state.settings);
    state = state.copyWith(settings: next);
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _prefsKey, value: jsonEncode(next.toJson()));
    } catch (_) {}
  }

  Future<void> setAuto(bool value) =>
      _patchSettings((s) => s.copyWith(auto: value));

  Future<void> setPull(bool value) =>
      _patchSettings((s) => s.copyWith(pull: value));

  Future<CloudSyncEngine> _engineFor() async {
    final existing = _engine;
    if (existing != null) return existing;
    final stores = ref.read(appStoresProvider);
    final engine = CloudSyncEngine(
      folder: _channel,
      gallery: stores.gallery,
      localGallery: stores.localGallery,
      supportRoot: await getApplicationSupportDirectory(),
    );
    await engine.load();
    return _engine ??= engine;
  }

  Future<CloudFolderStatus?> refreshStatus() async {
    if (!state.supported) return null;
    final CloudFolderStatus status;
    try {
      status = await _channel.status();
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(
          folder: const CloudFolderStatus(),
          error: _describe(e),
        );
      }
      return null;
    }
    if (!ref.mounted) return status;
    // 账本读不出来不影响文件夹状态:原生已经记住的文件夹不能显示成「没选过」
    state = state.copyWith(folder: status);
    try {
      final engine = await _engineFor();
      if (ref.mounted) state = state.copyWith(lastSyncAt: engine.lastSyncAt);
    } catch (e) {
      logd('[cloud-sync] 账本初始化失败: $e');
    }
    return status;
  }

  /// 弹系统文件夹选择器;选中后作废旧账本并马上同步一轮。
  ///
  /// 返回选中的文件夹;取消或出错返回 null,出错时原因在 [CloudSyncState.error]。
  Future<CloudFolderStatus?> pickFolder() async {
    if (!state.supported) return null;
    if (state.running) {
      state = state.copyWith(error: '正在同步，等这一轮结束再换文件夹');
      return null;
    }
    // 页面按选完后的 error 决定提示什么,不能拿上一次的旧错误顶上
    state = state.copyWith(error: null);
    final CloudFolderStatus? picked;
    try {
      picked = await _channel.pick();
    } catch (e) {
      if (ref.mounted) state = state.copyWith(error: _describe(e));
      return null;
    }
    if (picked == null || !ref.mounted) return null;
    // 原生已经存好书签了;这里抛出去就是「选完没反应」,界面停在没选过的样子
    try {
      await (await _engineFor()).reset();
    } catch (e) {
      logd('[cloud-sync] 换文件夹时作废账本失败: $e');
    }
    if (!ref.mounted) return picked;
    state = state.copyWith(
      folder: picked,
      lastSyncAt: 0,
      lastReport: null,
      error: picked.available ? null : '选中的文件夹暂时打不开，请重新选择',
    );
    if (picked.available) unawaited(sync());
    return picked;
  }

  /// 只忘掉文件夹,两边的图都原样保留。
  Future<void> disconnect() async {
    if (!state.supported || state.running) return;
    _autoTimer?.cancel();
    _waitTimer?.cancel();
    try {
      await _channel.clear();
    } catch (_) {}
    await (await _engineFor()).reset();
    state = state.copyWith(
      folder: const CloudFolderStatus(),
      lastSyncAt: 0,
      lastReport: null,
      error: null,
    );
  }

  void _scheduleAuto(Duration delay) {
    if (!state.supported || !state.settings.auto) return;
    if (state.folder?.ready != true) return;
    _autoTimer?.cancel();
    _autoTimer = Timer(delay, () => unawaited(sync(auto: true)));
  }

  /// 跑一轮同步。正在跑时再要一轮会排到这轮后面,不并发。
  ///
  /// [auto] 那轮遇到文件夹失效不报错,等用户进页面再看。
  Future<CloudSyncReport?> sync({
    bool restoreAll = false,
    bool auto = false,
  }) async {
    if (!state.supported) return null;
    if (state.running) {
      _again = true;
      return null;
    }
    var folder = state.folder;
    if (folder?.ready != true) folder = await refreshStatus();
    if (!ref.mounted) return null;
    if (folder == null || !folder.ready) {
      if (!auto) {
        state = state.copyWith(
          error: folder?.configured == true ? '找不到同步文件夹，请重新选择' : '还没有选择同步文件夹',
        );
      }
      return null;
    }
    _autoTimer?.cancel();
    if (!auto) _waitRounds = 0;
    state = state.copyWith(
      running: true,
      phase: CloudSyncPhase.checking,
      done: 0,
      total: 0,
      error: null,
    );
    try {
      final engine = await _engineFor();
      final report = await engine.run(
        pull: state.settings.pull,
        restoreAll: restoreAll,
        onProgress: (phase, done, total) {
          if (ref.mounted) {
            state = state.copyWith(phase: phase, done: done, total: total);
          }
        },
      );
      if (!ref.mounted) return report;
      if (report.downloaded > 0) {
        ref.read(localGalleryProvider.notifier).refreshFromStore();
      }
      state = state.copyWith(
        running: false,
        lastSyncAt: engine.lastSyncAt,
        lastReport: report,
        error: report.failed > 0
            ? '${report.failed} 张没同步成功：${report.firstError}'
            : null,
      );
      _scheduleWaitRetry(report.waiting);
      return report;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(running: false, error: _describe(e));
      }
      return null;
    } finally {
      if (_again && ref.mounted) {
        _again = false;
        _autoTimer?.cancel();
        _autoTimer = Timer(
          const Duration(seconds: 1),
          () => unawaited(sync(auto: true)),
        );
      }
    }
  }

  /// 占位文件已请求系统下载,隔一会儿再来拉;一直下不来(离线)就别无限轮询。
  void _scheduleWaitRetry(int waiting) {
    _waitTimer?.cancel();
    if (waiting == 0) {
      _waitRounds = 0;
      return;
    }
    if (++_waitRounds > 10) return;
    _waitTimer = Timer(
      const Duration(seconds: 20),
      () => unawaited(sync(auto: true)),
    );
  }

  String _describe(Object error) {
    // 安装包里没有 CloudFolderBridge(没跑 tool/prepare_ios.sh 就打包)时只会收到这个
    if (error is MissingPluginException) {
      return '安装包缺少 iCloud 同步的原生部分，请先运行 tool/prepare_ios.sh 再重新打包安装';
    }
    if (error is PlatformException) return error.message ?? error.code;
    return '$error';
  }
}
