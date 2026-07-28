# Plana App

NovelAI 第三方 Android 客户端。Flutter 编写,面向手机上的完整创作流程 ——
不是网页版套壳:提示词编辑、图库、Vibe 管理、局部重绘、本地超分都在本地跑。

> 与 NovelAI 官方无任何关联。图像由 NovelAI 生成,账号与生成内容产生的一切责任由使用者承担。

## 功能

- **生成** —— 多角色与角色位置、Vibe Transfer、img2img、局部重绘、队列与批量;
  后台走前台服务,进度上通知栏
- **提示词编辑器** —— 语法高亮、权重换算、标签补全(内置 Danbooru 离线库)、
  折叠组、多选批量移动/禁用/删除
- **图库** —— 本地落库,原图与元数据完整保留;导出时可清除元数据(含 alpha 隐写)
- **Vibe 库** —— `.naiv4vibe` 导入导出、逐模型编码管理、云端备份
- **导入** —— 从 PNG 元数据还原完整生成参数(含隐写图),逐项可选
- **本地超分** —— ncnn-vulkan,离线,不经过任何服务器

## 两种使用方式

**Token 直连 —— 完整可用,不依赖任何第三方服务**

填入自己的 NovelAI Token,请求直接发往 NovelAI。上面列出的功能**全部可用**。
这是本应用的默认形态。

**Bot 授权 —— 可选增强**

额外提供共享账号出图、公共 Vibe 库、AI 图片反推、增强标签补全,需要连接一个后端服务。

## 关于默认后端

应用内置的后端地址默认指向作者自建的服务器(`lib/core/net/backend_config.dart`
的 `kDefaultBackendBase`)。有几点需要讲清楚:

- **可选。** Token 直连模式下完全不会连接它。
- **可改。** 引导页与「我的 → 账号与接入」里可随时改成自建地址,或留空彻底不用。
- **增强功能是受限的。** 共享出图等能力需要授权,并非所有人可用 —— 这是资源成本
  决定的,与本项目是否开源无关。
- 自建时改掉该常量即可。**服务端不在本仓库内。**

## 构建

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```

签名走 `android/key.properties`(不在仓库内,模板见 `android/key.properties.example`)。
缺该文件时 release 会回落到 debug 签名 —— 自用没问题,但**与其他密钥签出的包互相装不上**。

版本号在 `pubspec.yaml` 与 `lib/core/app_info.dart` 两处,由 `test/app_info_test.dart`
钉住一致;`+N` 是 Android 的 versionCode,只能单调递增。

## 更新检查

应用只**检查** GitHub Releases 有无新版并提示,下载与安装交给浏览器和系统 ——
不申请安装权限,不自行安装任何东西。仓库地址见 `lib/core/app_info.dart` 的
`kGithubRepo`,留空则该功能静默关闭。

## 第三方内容与出处

| 内容 | 来源 | 说明 |
|---|---|---|
| 标签补全库 | Danbooru | 离线 TSV,随包分发 |
| 法典图鉴 | [quicktagcloud](https://novelai.quicktagcloud.com/) | 仅索引与跳转,数据不随包 |
| 超分模型 | [Upscayl](https://github.com/upscayl/upscayl) | **不随包分发**,首次使用时由设备直接从上游仓库下载 |

超分模型不内置是有意为之:上游未写明权重的再分发条款,由用户设备自源站获取可以
整个绕开该问题。详见 `lib/features/gallery/upscale_model_store.dart` 顶部说明。

第三方内容的版权归其各自作者所有,本项目仅作索引与调用。

## 许可

Copyright (C) 2026 Sora_Light

本程序是自由软件:你可以依据自由软件基金会发布的 GNU 通用公共许可证(GPL)
第三版、或(你可选择的)任何更新版本,重新分发和/或修改它。

分发本程序是希望它能有用,但**不作任何担保**;甚至不含对适销性或特定用途
适用性的默示担保。详见 GNU 通用公共许可证。

许可证全文见 [LICENSE](LICENSE),亦可访问 <https://www.gnu.org/licenses/>。

> **这意味着什么:** 你可以自由使用、修改、分发本项目。但如果你分发修改后的
> 版本(包括打包成 APK 分发),**必须同样以 GPL-3.0 开放你的源码**。
> 换皮闭源重新分发是不允许的。

### 不在 GPL 范围内的部分

**代码之外的内容一律不适用上述授权:**

- **应用图标**(`icons/app_icon.png`、`assets/app_icon.png`、`android/**/mipmap-*`)——
  图像由本项目作者绘制,但**画面中的角色形象属于第三方游戏作品**。该图标
  **保留所有权利,不随 GPL 一同授权**:fork 本项目请自行替换图标,不要连同分发。
- 标签库、法典数据、超分模型等第三方内容,版权归各自作者所有,详见
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 免责声明

本项目是非官方的第三方客户端,与 NovelAI (Anlatan) 无关联、未获其背书。
使用者需自行遵守 NovelAI 的服务条款。因使用本应用导致的账号问题、内容问题
及任何其他后果,均由使用者自行承担。
