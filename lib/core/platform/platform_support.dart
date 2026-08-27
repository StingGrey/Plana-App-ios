import 'package:flutter/foundation.dart';

bool get isIOSPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// 本项目目前只有 Android 实现了前台服务与生成进度通知。
///
/// 使用 [defaultTargetPlatform] 而不是直接散落 `Platform.isAndroid`，让界面测试
/// 可以通过 `debugDefaultTargetPlatformOverride` 覆盖目标平台。
bool get supportsGenerationProgressNotifications =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Android 前台服务能维持当前的流式 HTTP / WebSocket 生成；iOS 首版不能。
bool get supportsBackgroundGeneration =>
    supportsGenerationProgressNotifications;

/// iOS 更新由 Xcode / TestFlight / App Store 管理，不打开只含 Android 安装包的
/// GitHub Release 下载流程。
bool get supportsGithubReleaseUpdate =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
