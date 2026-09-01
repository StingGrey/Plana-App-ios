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

## 一键生成 iOS 工程

要求：

- macOS；
- Xcode（首次安装后至少启动一次）；
- Flutter 3.44 或更新版本；
- CocoaPods。

在项目根目录执行：

```bash
chmod +x tool/prepare_ios.sh
./tool/prepare_ios.sh
```

脚本会：

1. 用你本机 Flutter 的模板创建 `ios/`；
2. 设置最低 iOS 13；
3. 写入照片读取、照片保存和局域网权限说明；
4. 仅允许 ATS 本地网络访问，不为公网全局放开明文流量；
5. 生成不含透明通道的 iOS App Icon；
6. 安装 Pods；
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

## GitHub Actions 云端构建

仓库已包含 `.github/workflows/build-ios-unsigned.yml`，可使用 GitHub 提供的
macOS runner 构建未签名 IPA，不要求自己的电脑安装 Xcode。

1. 把整个项目推到 GitHub；
2. 打开仓库的 **Actions**；
3. 选择 **Build unsigned iOS IPA**；
4. 点击 **Run workflow**；
5. 完成后在该次运行底部下载 `Plana-App-iOS-unsigned` Artifact；
6. 解压 Artifact，得到 `Plana-App-unsigned.ipa` 与 SHA-256 文件；
7. 使用 Sideloadly、AltStore 等工具，以自己的 Apple ID 重签并安装。

该 IPA 未签名，不能直接点开安装。工作流不会接触 Apple 密码、证书或
Provisioning Profile。若以后要上传 TestFlight，应另外建立签名工作流，并把
证书和 App Store Connect API Key 存入 GitHub Secrets，切勿写入仓库。

## 首轮真机检查

- Token 与账号密码登录后重启仍能从 Keychain 读取；
- 选择单图、多图，以及从系统 Files 导入文件；
- 保存 PNG/JPG、批量保存和自定义相册；
- 导入/导出 `.naiv4vibe`、bundle 与 JSON；
- 直连生成、Bot 生成、取消、队列及有限循环；
- 锁屏或切换 App 后回到前台的错误提示是否清楚；
- 局域网自建后端；若使用明文 HTTP，优先改成 HTTPS。

## 后台生成的第二阶段方案

- 直连 NovelAI：用 Swift `URLSession` 后台传输承接非流式端点；
- 自建后端：提交服务器任务后保存 task ID，恢复前台时继续轮询；
- 完成提醒：由服务器通过 APNs 推送；
- 灵动岛：新增 ActivityKit Widget Extension，仅展示任务状态，不能用于保活。

## 分发提醒

仓库采用 GPL-3.0。正式 App Store 分发前应确认 GPLv3 与 Apple 分发条款、素材权利、NovelAI 第三方客户端政策及生成内容审核要求。本文不是法律意见。
