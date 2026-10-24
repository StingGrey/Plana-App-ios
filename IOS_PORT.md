# Plana App iOS 移植说明

## 当前状态

这个分支提供可落地的 **iOS 前台版**：核心 Flutter 功能共用，移动端图库选择、照片保存、Keychain、文件导入导出与平台文案已做适配。

当前刻意不伪装支持以下能力：

- App 切到后台后继续维持 NovelAI 流式 HTTP 或后端 WebSocket；
- iOS Live Activity / Dynamic Island；
- 从 GitHub Release 下载 Android APK 的应用内更新流程。

当前 iOS 前台版另外提供：本地图库（自动汇总生成历史，也支持照片/Files 导入、元数据搜索、分类、收藏、集合与批量操作）、
在线画廊（Danbooru / Safebooru / Gelbooru / AI TAG / 法典图鉴）、生成队列管理、生成结果详情、
固定词库与精准参考库。文件夹扫描依赖桌面/Android 文件选择器；iOS 上使用系统 Files 多选导入，
避免承诺不存在的长期目录访问权限。

生成时请保持 App 在前台。Android 原有前台服务与通知逻辑不受影响。

## iCloud 同步

「我的 → iCloud 同步」里选一个 iCloud Drive 文件夹后，生成历史与外部导入的原图会以
`Plana_<生成时刻>_<哈希>.png` 写进去（PNG 元数据原样保留）；另一台设备选同一个文件夹，
就会把对方的图拉进本地图库。出新图、回到前台时自动同步，也可以只做单向备份。

走「用户选的文件夹」而不是 CloudKit：重签用的描述文件不带 iCloud 容器，带 iCloud
entitlement 的包装上去起不来；文件夹授权不需要任何 entitlement，免费 Apple ID 重签也能用。
原生部分在 `tool/ios/SceneDelegate.swift` 的 `CloudFolderBridge`（书签 + NSFileCoordinator 读写）。

删除不双向同步：在哪台设备删都只删本机，文件夹里的图请到「文件」App 里删。

**重签时包名必须和描述文件的 App ID 一致。** 用显式 App ID 的描述文件（例如
`XXXXXXXXXX.app.example.name`）重签时，要把包名改成 `app.example.name`；只换证书、
保留 `com.sora214.plana.app` 的话，App 能装能用，但系统文件夹选择器点「打开」毫无反应，
面板也不关 —— iPadOS 在 App 进程里解析选中的文件夹时被拒（日志：`Could not resolve
bookmark … NSCocoaErrorDomain 257`、`Tried to call delegate -documentBrowser:didPickDocumentURLs:
with an empty array of items`），根本不会回调 App。通配 App ID（`XXXXXXXXXX.*`）的描述文件
签名时 App ID 跟着包名走，按理不会碰到（未实测）。
改包名等于装一个新 App，旧包里的图库与设置不会自动带过去。

## 一键生成 iOS 工程

要求：

- macOS；
- Xcode（首次安装后至少启动一次）；
- Flutter 3.44.9 或更新版本（Dart 3.12.2+）；
- 若生成的工程含有 `ios/Podfile`，还需安装 CocoaPods。

在项目根目录执行：

```bash
chmod +x tool/prepare_ios.sh
./tool/prepare_ios.sh
```

脚本会：

1. 用你本机 Flutter 的模板创建 `ios/`；
2. 设置最低 iOS 16；
3. 写入照片读取、照片保存和局域网权限说明；
4. 仅允许 ATS 本地网络访问，不为公网全局放开明文流量；
5. 生成不含透明通道的 iOS App Icon；
6. 获取依赖；工程使用 CocoaPods 时安装 Pods；
7. 执行一次无签名 Debug 编译检查。

如只想生成工程而暂不编译：

```bash
./tool/prepare_ios.sh --skip-build
```

## 真机运行

1. 打开 `ios/Runner.xcworkspace`，不要打开 `.xcodeproj`；
2. 选择 `Runner` target；
3. 在 **Signing & Capabilities** 选择自己的 Team；
4. 如果 Bundle Identifier 被占用，改成你自己的唯一标识；
5. 连接 iPhone 并点击 Run。

免费 Apple ID 签名通常只能在设备上保留约 7 天；正式 TestFlight / App Store 分发需要 Apple Developer Program。

## 本地构建未签名 IPA

在 macOS 的项目根目录准备工程并编译 Release 版本：

```bash
./tool/prepare_ios.sh --skip-build
flutter build ios --release --no-codesign
```

编译产物是 `build/ios/iphoneos/Runner.app`。在临时目录打包，避免混入旧文件：

```bash
plana_package_dir=$(mktemp -d)
mkdir -p "$plana_package_dir/Payload"
ditto build/ios/iphoneos/Runner.app "$plana_package_dir/Payload/Runner.app"
ditto -c -k --keepParent "$plana_package_dir/Payload" build/ios/Plana-App-unsigned.ipa
rm -rf "$plana_package_dir"
unzip -tq build/ios/Plana-App-unsigned.ipa
shasum -a 256 build/ios/Plana-App-unsigned.ipa > build/ios/Plana-App-unsigned.sha256
```

该 IPA 未签名，需用 Sideloadly、AltStore 等工具，以自己的 Apple ID 重签安装。
本地构建完成后可将 IPA 与 SHA-256 文件上传到 GitHub Releases。

## 首轮真机检查

- Token 与账号密码登录后重启仍能从 Keychain 读取；
- 选择单图、多图，以及从系统 Files 导入文件；
- 保存 PNG/JPG、批量保存和自定义相册；
- 导入/导出 `.naiv4vibe`、bundle 与 JSON；
- 直连生成、Bot 生成、取消、队列及有限循环；
- 锁屏或切换 App 后回到前台的错误提示是否清楚；
- 局域网自建后端；若使用明文 HTTP，优先改成 HTTPS。
- iCloud 同步：选 iCloud Drive 文件夹、重启后仍记得文件夹、两台设备互相拉到对方的图。

## 后台生成的第二阶段方案

- 直连 NovelAI：用 Swift `URLSession` 后台传输承接非流式端点；
- 自建后端：提交服务器任务后保存 task ID，恢复前台时继续轮询；
- 完成提醒：由服务器通过 APNs 推送；
- 灵动岛：新增 ActivityKit Widget Extension，仅展示任务状态，不能用于保活。

## 分发提醒

仓库采用 GPL-3.0。正式 App Store 分发前应确认 GPLv3 与 Apple 分发条款、素材权利、NovelAI 第三方客户端政策及生成内容审核要求。本文不是法律意见。
