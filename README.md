<div align="center">

<img src="assets/app_icon.png" width="96" alt="Plana App">

# Plana App

**NovelAI 移动创作端** —— 第三方 Android 客户端,覆盖提示词编辑、生成、图库与素材管理的完整流程

[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/mc5024/Plana-App?label=release)](https://github.com/mc5024/Plana-App/releases)
[![Android](https://img.shields.io/badge/Android-7.0%2B-3ddc84?logo=android&logoColor=white)](#构建)
[![Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B?logo=flutter&logoColor=white)](https://flutter.dev)

</div>

> 第三方客户端,与 NovelAI (Anlatan) **无关联、未获其背书**。图像由 NovelAI 生成,
> 账号与生成内容产生的一切责任由使用者承担。

---

<!--
  截图位 —— 把图片放进 screenshots/,文件名对上下面这张表,
  然后删掉包住本段的那两行注释标记,截图区即生效。
  竖屏截图建议统一 1080×2400 或等比。

## 截图

| 创作页 | 提示词编辑器 | 图库 |
|:---:|:---:|:---:|
| <img src="screenshots/generate.png" width="240" alt="创作页"> | <img src="screenshots/editor.png" width="240" alt="提示词编辑器"> | <img src="screenshots/gallery.png" width="240" alt="图库"> |

| 局部重绘 | 灵感库 | 法典图鉴 |
|:---:|:---:|:---:|
| <img src="screenshots/inpaint.png" width="240" alt="局部重绘"> | <img src="screenshots/inspiration.png" width="240" alt="灵感库"> | <img src="screenshots/codex.png" width="240" alt="法典图鉴"> |

-->

## 亮点

- **提示词编辑器** 注音富文本与芯片流两种形态,底栏切换、文本状态共用;词条栏吸附于键盘上方,
  提供权重增减与清除、热度、复制、禁用、删除及 SD 语法转换。

- **标签补全与翻译** 支持中文搜词,候选附 Danbooru 摘要与别名,译文标注于词下;可切换为内置离线词库。

- **后台生成** 前台服务保活,进度常驻通知栏;Android 16 起支持灵动岛与状态栏胶囊。

- **队列与循环** 入队即冻结参数快照,后续编辑不影响已排任务;循环可指定张数或不限,随时暂停。

- **NAI 5** 两档模型;角色支持画布任意坐标定位,单图上限 32 个;支持透明背景与引号自动转画面文字。

- **参数导入** 从 PNG 元数据逐项还原生成参数,识别 NAI 隐写信息,兼容 ComfyUI 与 A1111。

- **本地图库** 原图、缩略图与参数快照本地留存,可按模型与标签检索;导出时元数据可保留、清除或改写。

- **素材库** 灵感库按角色 / 画风 / 场景归类并可生成预览图;Vibe 库支持 `.naiv4vibe` 导入导出与逐模型编码管理;
  角色参考图库按内容去重。

- **法典图鉴** 接入社区整理的成品提示词、画师串与合集包,可整套(含多角色)加入创作页。

- **用量统计** 直连模式下本机按天记账,统计张数、免费张数与消耗点数,提供趋势图与当日明细。

## 其余功能

### 创作

| 功能 | 说明 |
|---|---|
| 模型 | NAI 5.0 Full / Curated · 4.5 Full / Curated · 4.0 Full / Curated |
| 多角色 | 每角色独立正负向词;位置支持网格(V4 系)与任意坐标(V5),留空则自动排布 |
| Vibe Transfer | 多图、逐图强度可调;编码结果按图缓存,同图不重复扣点 |
| 角色参考 | 4.5 系;迁移模式可选角色 / 画风 / 两者,强度与保真度独立调节 |
| 图生图 | 强度与噪声可调,可由图库任意一张直接发起 |
| 局部重绘 · 裁切 · 扩图 | 涂抹遮罩即可,结果仅将改动区域贴回原图;裁切与四向扩图共用同一画布 |
| 提示词预设 | 内置档位对齐官方,自定义可选拼接位置;导入图片时自动识别并剥离 |
| 分辨率 | 预设档与自定义;实时判定免费 / 收费 / 超限 |
| 费用预估 | Anlas 公式对齐官方,含免费档判定与 Vibe 编码、角色参考附加费 |
| Token 读数 | 内置官方同款分词器,非估算;上限按模型取值 |
| 参数说明 | 各参数附 ⓘ 说明 |
| 工作台持久化 | 提示词、角色、参考图、参数与面板状态重启后原样恢复 |
| 界面自定义 | 创作页模块可显隐,卡头长按拖拽调序 |

### 图与素材

| 功能 | 说明 |
|---|---|
| 放大 | 传统超分 4× · V5 扩散超分 2× · 重绘放大(倍率与强度可调) |
| 「用作」 | 任意图片可直接用作图生图底图、Vibe 或角色参考 |
| 图库手势 | 按住抬起预览;胶片条拖至垃圾条删除;网格多选批量分享 / 保存 / 删除 |
| 工具箱 | SD ⇄ NAI 权重语法整串互转(带高亮,可直接导入创作页)、图片元数据查看与改写 |
| 从网页版迁移 | 导入 `novelai_web_ui` 备份文件,Vibe、角色参考、OC、画师串一次性落位 |

### 账号与设置

| 功能 | 说明 |
|---|---|
| 两种登录 | 粘贴 Token,或使用 NAI 账号密码登录(密码本机派生密钥,不出设备、不落盘) |
| 外观与触感 | 深浅模式跟随系统、主题色可选、振动反馈开关 |
| 生成设置 | 完成通知、限流后自动重试(间隔与次数)、图库默认保存格式与元数据策略 |
| 存储管理 | 分类占用统计与逐项清理;重复文件仅存一份,启动时自动回收无引用数据 |
| 检查更新 | 仅比对 GitHub Releases 并提示,下载与安装交由浏览器和系统,不申请安装权限 |

## 两种接入方式

**Token 直连 —— 完整可用,不依赖任何第三方服务。** 填入自己的 NovelAI Token
(或用账号密码登录),请求直接发往 NovelAI。**上面列出的功能全部可用**,这是本应用的默认形态。

应用另外内置了一个可选的后端地址(`lib/core/net/backend_config.dart` 的
`kDefaultBackendBase`),用于少量增强能力。它是**可选的** —— 直连模式下完全不会连接它,
引导页与「我的 → 账号与接入」里可随时改成自建地址或留空彻底不用。**服务端不在本仓库内。**

## 构建

要求 Android 7.0(API 24)以上;compileSdk 36(灵动岛进度需要)。

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```

签名走 `android/key.properties`(不在仓库内,模板见 `android/key.properties.example`)。
缺该文件时 release 会回落到 debug 签名 —— 自用没问题,但**与其他密钥签出的包互相装不上**。

版本号在 `pubspec.yaml` 与 `lib/core/app_info.dart` 两处,由 `test/app_info_test.dart`
钉住一致;`+N` 是 Android 的 versionCode,只能单调递增。

```bash
flutter analyze && flutter test
```

约 8 万行 Dart、60 个测试文件 / 640+ 用例。分词器、Anlas 公式、Vibe 哈希口径、
NAI 5 载荷契约、Argon2id 派生均由参考向量钉住,改动对不上即失败。

## 致谢与出处

本项目站在这些工作之上。

### 数据与上游

| 来源 | 用途 |
|---|---|
| [Danbooru](https://danbooru.donmai.us/) | 标签体系;离线补全词库(`assets/danbooru.tsv`,随包分发) |
| [DanbooruSearchOnline](https://github.com/SuzumiyaAkizuki/DanbooruSearchOnline) · SuzumiyaAkizuki | 中文标签名与一句话简介的建库产物,增强补全的中文搜词与译名出自于此 |
| [quicktagcloud](https://novelai.quicktagcloud.com/) | 法典图鉴的全部数据(词条 / 画师串 / 合集 / 例图)。**只读接入**,数据不随包分发,本应用不改也不发布法典内容 |
| [@huggingface/tokenizers](https://github.com/huggingface/tokenizers) | T5 分词器移植的参照实现 —— token 读数能与官方对齐,靠的是它的 encode 管线语义 |
| [NovelAI](https://novelai.net/) · Anlatan | 图像生成服务本身。本项目是第三方客户端,与其无关联 |

第三方内容的版权归其各自作者所有,本项目仅作索引与调用。

### 开源库

由 [Flutter](https://flutter.dev)(BSD-3-Clause,© The Flutter Authors)构建,并使用:

- **状态与界面** — [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) ·
  [animations](https://pub.dev/packages/animations) ·
  [material_color_utilities](https://pub.dev/packages/material_color_utilities) ·
  [cupertino_icons](https://pub.dev/packages/cupertino_icons)
- **网络与编解码** — [http](https://pub.dev/packages/http) ·
  [archive](https://pub.dev/packages/archive) ·
  [msgpack_dart](https://pub.dev/packages/msgpack_dart) ·
  [image](https://pub.dev/packages/image) ·
  [crypto](https://pub.dev/packages/crypto) ·
  [cryptography](https://pub.dev/packages/cryptography)(Blake2b + Argon2id,账号密码登录靠它) ·
  [unorm_dart](https://pub.dev/packages/unorm_dart)
- **平台能力** — [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) ·
  [photo_manager](https://pub.dev/packages/photo_manager) ·
  [photo_manager_image_provider](https://pub.dev/packages/photo_manager_image_provider) ·
  [path_provider](https://pub.dev/packages/path_provider) ·
  [gal](https://pub.dev/packages/gal) ·
  [file_picker](https://pub.dev/packages/file_picker) ·
  [url_launcher](https://pub.dev/packages/url_launcher) ·
  [share_plus](https://pub.dev/packages/share_plus)
- **构建期** — [flutter_lints](https://pub.dev/packages/flutter_lints) ·
  [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons)

以上均为宽松许可(BSD / MIT / Apache-2.0),逐包清单见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md);应用内「关于 → 开源许可」亦有完整入口。

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

第三方内容(标签库、法典数据)不在本许可范围内,版权归各自作者所有,
详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 免责声明

本项目是非官方的第三方客户端,与 NovelAI (Anlatan) 无关联、未获其背书。
使用者需自行遵守 NovelAI 的服务条款。因使用本应用导致的账号问题、内容问题
及任何其他后果,均由使用者自行承担。
