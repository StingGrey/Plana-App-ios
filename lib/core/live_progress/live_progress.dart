import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// 该设备/权限下的上岛能力(供 UI 决定是否提示"仅新系统可上岛")。
class LiveCaps {
  const LiveCaps({this.sdkInt = 0, this.canPromote = false});

  final int sdkInt;

  /// API 36+ 且已获准时为 true:进度会被系统提升到状态栏胶囊/锁屏(灵动岛)。
  final bool canPromote;
}

/// 后台生成进度:前台服务(保活)+ 常驻通知,API 36 自动上灵动岛/状态栏胶囊。
///
/// 纯原生实现,见 android/.../LiveProgressService.kt。非 Android 平台全部 no-op,
/// 且所有调用都吞异常——通知只是锦上添花,绝不能因它拖垮生成主流程。
class LiveProgress {
  LiveProgress._();
  static final LiveProgress instance = LiveProgress._();

  static const MethodChannel _ch = MethodChannel('plana/live_progress');

  bool get _on => Platform.isAndroid;
  bool _permAsked = false;
  bool _started = false;

  /// 前台服务/通知是否已在。循环、队列续张时据此就地 [update],而不是再 [start]
  /// ——重复 start 会 startForegroundService 重拉,让灵动岛胶囊消失再弹出。
  bool get active => _started;

  /// 首次使用前拉起通知权限(API 33+),幂等;失败静默。
  Future<void> ensurePermission() async {
    if (!_on || _permAsked) return;
    _permAsked = true;
    await _quiet('requestNotificationPermission');
  }

  Future<LiveCaps> capabilities() async {
    if (!_on) return const LiveCaps();
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('capabilities');
      return LiveCaps(
        sdkInt: (m?['sdkInt'] as int?) ?? 0,
        canPromote: (m?['canPromote'] as bool?) ?? false,
      );
    } catch (_) {
      return const LiveCaps();
    }
  }

  /// 开启前台服务 + 初始通知。[total]>0 时用确定态进度条(0/total),这样从
  /// 「准备」起就走可上岛的 ProgressStyle(而非等有步数才提升,单图会错过整段)。
  ///
  /// [title] 是通知的主行,**要带状态**:通知头已经写着应用名了,主行再写一遍
  /// 「Plana」等于白占一行。[text] 是副行,没有可留空(留空则不渲染那一行)。
  Future<void> start({
    String title = '准备生成…',
    String text = '',
    int total = 0,
  }) {
    _started = true;
    return _quiet('start', {'title': title, 'text': text, 'total': total});
  }

  /// 刷新进度。[step]<=0 或 [indeterminate] 走不确定态;否则 step/total 进度条。
  /// [short] 是状态栏胶囊文案(≤7 字符最稳,如 "14/28")。
  Future<void> update({
    int step = 0,
    int total = 0,
    bool indeterminate = false,
    String title = 'Plana',
    String text = '',
    String short = '',
  }) => _quiet('update', {
    'cur': step,
    'total': total,
    'indeterminate': indeterminate,
    'title': title,
    'text': text,
    'short': short,
  });

  /// 收尾。能上岛时先把岛改成完成态停留几秒(否则岛是直接消失的,没有完成反馈),
  /// 再按 [keep] 落地:
  ///  - [keep] true(应用在后台):留一条非常驻、可点开的通知当回来的入口;
  ///  - [keep] false(应用在前台):通知一并撤掉,结果本来就在眼前。
  Future<void> finish({
    String title = '生成完成',
    String text = '',
    String short = '完成',
    bool keep = true,
  }) {
    _started = false;
    return _quiet('finish', {
      'title': title,
      'text': text,
      'short': short,
      'keep': keep,
    });
  }

  /// 静默撤掉通知与服务(前台时用)。
  Future<void> stop() {
    _started = false;
    return _quiet('stop');
  }

  Future<void> _quiet(String method, [Object? args]) async {
    if (!_on) return;
    try {
      await _ch.invokeMethod(method, args);
    } catch (_) {
      // 通知层任何失败都不应影响生成
    }
  }
}
