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

/// Google 云端硬盘备份要在 Info.plist 里配 GIDClientID 与回调 URL scheme;
/// iOS 工程由 prepare_ios.sh 现生成、重签用的也不是我们的 OAuth 客户端,
/// 没配就点「连接」会直接闪退。iOS 走「我的 → iCloud 同步」。
bool get supportsGoogleDriveBackup =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
