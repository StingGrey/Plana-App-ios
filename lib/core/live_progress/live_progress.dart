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

  /// 开启前台服务 + 初始(不确定态)通知。
  Future<void> start({String title = 'Plana', String text = '准备生成…'}) =>
      _quiet('start', {'title': title, 'text': text});

  /// 刷新进度。[step]<=0 或 [indeterminate] 走转圈;否则 step/total 进度条。
  /// [short] 是状态栏胶囊文案(≤7 字符最稳,如 "14/28")。
  Future<void> update({
    int step = 0,
    int total = 0,
    bool indeterminate = false,
    String title = 'Plana',
    String text = '',
    String short = '',
  }) =>
      _quiet('update', {
        'cur': step,
        'total': total,
        'indeterminate': indeterminate,
        'title': title,
        'text': text,
        'short': short,
      });

  /// 收尾:留一条非常驻、可点开的完成/失败通知(后台时用)。
  Future<void> finish({String title = 'Plana', String text = '生成完成'}) =>
      _quiet('finish', {'title': title, 'text': text});

  /// 静默撤掉通知与服务(前台时用)。
  Future<void> stop() => _quiet('stop');

  Future<void> _quiet(String method, [Object? args]) async {
    if (!_on) return;
    try {
      await _ch.invokeMethod(method, args);
    } catch (_) {
      // 通知层任何失败都不应影响生成
    }
  }
}
