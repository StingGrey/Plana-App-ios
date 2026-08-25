<div align="center">

<img src="assets/app_icon.png" width="96" alt="Plana App">

# Plana App

**NovelAI 移动创作端** —— 不是网页版套壳,是把手机能做而浏览器做不到的那部分做出来

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

- **提示词编辑器有两种形态** 一种是可以直接改的正文,权重当场上色、中文译文写在词的正下方;
  另一种把每个标签变成一颗方块,点一下选中、按住搬走,适合大改。底栏一键切换,改到一半切过去也不丢。

- **中文译文就标在词下面** 不用离开编辑器去查。本地词库先查,查不到再问服务器,查过的记在本机,下次即时出。

- **权重面板贴着键盘** 点中一个词,加减权重、清空权重、看热度、复制、禁用、删除全在这一排。
  数值可以按住连续调;别人给的 SD 写法能一键转成 NAI 的;疑似漏了逗号的数字会被标出来提醒你。

- **补全能打中文,还带释义** 输中文也能搜到英文标签,候选带 Danbooru 词条的摘要和别名。
  想彻底离线就切到内置词库,断网照样写词。

- **生成丢后台就不用管了** 进度进通知栏,新一点的安卓会直接上灵动岛。切出去刷别的、锁屏,回来图已经在图库里。

- **可以排队,也可以让它自己一直画** 排上去的任务参数当场冻结,你接着改编辑器不会影响已经排好的。
  循环能指定张数或者一直跑,随时喊停。

- **NAI 5 支持到位** 两档模型都能用;角色可以摆在画面任意位置,一张图最多 32 个;支持透明背景;
  提示词里打引号会自动变成画面里的文字。

- **别人的图丢进来,参数拿得回来** 逐项列出来给你勾,要哪些填哪些。NAI 藏在像素里的隐写信息也读得出,
  ComfyUI、A1111 出的图同样认。

- **导出时元数据你说了算** 原样保留、彻底清除,或者换成你自己写的一段话。清除会连藏在像素里的那份一起抹掉,
  但不会把透明的图弄成实心。

- **图库存在你自己机器上** 原图、缩略图、参数快照都在本地,重启不丢,还能按模型和标签搜。

- **法典图鉴翻着就能用** 社区整理好的成品提示词、画师串、合集包,对着例图挑,整套(带多角色)一键加进创作页。

- **灵感库收你自己的词条** 角色、画风、场景分类存着,常用的自动靠前;还能给每条生成一张预览图,下次一眼认出来。

- **Vibe 库与角色参考库** 官方的 `.naiv4vibe` 文件随便导入导出,每个模型的编码分开管;
  角色参考图单独一个库,同一张图不会存两份。

- **用量自己看得见** 不走后端也能记账:每天出了几张、几张免费、花了多少点,趋势图和当天明细都在。

## 其余功能

### 创作

| 功能 | 说明 |
|---|---|
| 模型 | NAI 5.0 Full / Curated · 4.5 Full / Curated · 4.0 Full / Curated |
| 多角色 | 每个角色独立的正负向词;位置支持格子(V4 系)和任意坐标(V5),留空就自动排 |
| Vibe Transfer | 多图、逐图调强度;编码结果按图存,同一张图不会重复扣点 |
| 角色参考 | 4.5 系;可选只搬角色、只搬画风或都搬,强度与保真度分开调 |
| 图生图 | 强度和噪声可调,图库里任意一张都能直接开 |
| 局部重绘 · 裁切 · 扩图 | 手指涂遮罩就行,结果只把改动的地方贴回原图;裁切和四向扩图共用一块画布 |
| 提示词预设 | 内置的和官方一致,自定义的可以选拼在前面还是后面;导入图片时会自动认出来并剥掉 |
| 分辨率 | 预设档加自定义;拖的同时就告诉你这张是免费、扣点还是超限 |
| 费用预估 | 生成按钮上写多少点,事后账单里就是多少点 |
| Token 读数 | 内置官方同款分词器,不是估算;上限按模型走 |
| 参数说明 | 每个参数旁边挂了 ⓘ,不确定就点开看 |
| 工作台不丢 | 杀进程重进,提示词、角色、参考图、面板开合原样回来 |
| 界面可自定义 | 创作页的模块自由显隐,卡头长按拖着调顺序 |

### 图与素材

| 功能 | 说明 |
|---|---|
| 放大 | 三条路:传统超分 4× · V5 扩散超分 2× · 重绘放大(倍率和强度可调) |
| 「用作」 | 任意一张图直接拿去当图生图底图、Vibe 或角色参考 |
| 图库手势 | 按住抬起看大图,胶片条拖到垃圾桶就删,网格多选批量分享 / 保存 / 删除 |
| 工具箱 | SD ⇄ NAI 权重语法整串互转(结果带高亮,可直接导入创作页)、图片元数据查看与改写 |
| 从网页版迁移 | 导入 `novelai_web_ui` 的备份文件,Vibe、角色参考、OC、画师串一次全落位 |

### 账号与设置

| 功能 | 说明 |
|---|---|
| 两种登录 | 粘贴 Token,或者直接用 NAI 账号密码 —— 密码在本机算成密钥,不出设备也不落盘 |
| 外观与触感 | 深浅模式跟随系统、主题色可选、振动反馈开关 |
| 生成设置 | 完成通知、被限流后自动重试(间隔与次数)、图库默认保存格式与元数据策略 |
| 存储管理 | 分类看占用、逐项清理;重复的图只存一份,启动时自动回收没人用的 |
| 检查更新 | 只比对 GitHub Releases 然后提示你,下载和安装交给浏览器和系统 —— 不申请安装权限 |

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
NAI 5 载荷契约、Argon2id 派生这几处都由参考向量钉死 —— 改动对不上直接红。

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
