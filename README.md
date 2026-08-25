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

### 提示词编辑器有两种形态,都是全屏的

**注音富文本** —— 权重原样内联并上色,译文绘在词的正下方;光标点进词里出词条栏,
点在逗号或空隙处出补全。
**芯片流** —— 一枚标签一颗 chip,点选、多选、⊕ 搬运、折叠成组、批量禁用/删除,
打字走尾部输入框。

底栏一键切换,两种形态共用同一份文本状态,切回来一个字都不丢。补全条永远吸在键盘
正上方 —— 移动端只剩 40% 可用高度,提示词编辑必须独占整屏。

### Token 读数与官方逐数一致

内置 NAI 的 T5 分词器,**不是估算**:Precompiled 归一化 → Metaspace → Unigram
Viterbi → fuse_unk 整条管线移植,词表就是网页端那一份 JSON(字节级同源)。
NAI 5 的 703 / 1471 上限按模型走,创作页卡头与编辑器顶栏实时显示 `x / 上限`。

### 费用预估和事后账单不差一点

Anlas 公式逐字对齐官方前端(含 V5 的 ×1.5 系数与那两次必须分开做的取整),
免费档判定、Vibe 编码费、角色参考附加费全部计入。生成按钮上写多少点,账单里就是多少点。

### 局部重绘、裁切、扩图,全在手机上完成

手指涂遮罩(按 8×8 网格量化,对齐 VAE 潜空间,**所见即所发**),发送框自动 64 对齐,
结果只把改动区域贴回原图。裁切与四向扩图共用同一块画布,按住可与原图逐像素对位比对。

### 生成放后台不会断

前台服务保活 + 常驻通知报进度;Android 16(API 36)自动上**灵动岛 / 状态栏胶囊**。
切出去刷别的、锁屏,回来图已经在图库里等着。

### 图库在本地,元数据你说了算

原图 + 缩略图 + 参数快照落本地,重启不丢,可按模型与标签检索。导出时可选 PNG 无损 /
JPG,元数据**保留 / 清除 / 改写成自定义提示词**三选一 —— 清除会连同藏在 alpha 最低位的
隐写数据一起抹掉,但**不会把透明图拍成实心**。

## 功能全景

### 创作

| 功能 | 说明 |
|---|---|
| **NAI 5** | 两档模型全支持:角色**自由定位**(单图最多 32 个)、透明背景、引号内容自动转 `text:` 块、V5 扩散超分 |
| **模型** | NAI 5.0 Full / Curated · 4.5 Full / Curated · 4.0 Full / Curated |
| **多角色** | 每角色独立正负向词;位置支持 A1–E5 网格(V4 系)与连续坐标(V5),留空则自动排布 |
| **Vibe Transfer** | 多图、逐图强度与信息提取;编码结果按内容寻址缓存,同一张图不重复扣点 |
| **角色参考** | 4.5 系;迁移模式 / Strength / Fidelity 三档可调 |
| **图生图** | 强度与噪声可调,可从图库任意一张直接开 |
| **局部重绘 / 裁切 / 扩图** | 见上 |
| **队列与循环** | 入队瞬间冻结参数快照,之后随便改编辑器都不影响已排的;循环可设张数或无限,随时暂停 |
| **提示词预设** | 内置档位对齐官方,自定义可选拼接位置;导入图片时自动识别并剥离 |
| **分辨率** | 预设档 + 自定义(64 对齐);**免费 / 收费 / 超限**三档实时判定,不用自己算像素预算 |
| **参数说明** | 每个参数旁挂 ⓘ 说明,文案与网页端同源 |
| **工作台持久化** | 提示词、角色、参考图、参数、面板开合 —— 杀进程重进原样回来 |

### 素材与灵感

| 功能 | 说明 |
|---|---|
| **Vibe 库** | `.naiv4vibe` / `.naiv4vibebundle` 导入导出、逐模型编码管理、批量预编码、本地落库 |
| **灵感库** | 角色 / 画风 / 场景 / 其他 四类词条,标签池与最近使用;可为条目生成预览图;画风可标注适用模型并按模型档筛选 |
| **法典图鉴** | 只读接入 [quicktagcloud](https://novelai.quicktagcloud.com/) 的成品词条、画师串、合集包 —— 可收藏、可整套(含多角色)加进提示词 |
| **角色参考图库** | 裸原图一图一条,内容寻址天然去重 |
| **标签补全** | 增强档(Danbooru wiki 摘要 + 中文搜词与译名)/ 离线档(内置词库,完全不联网),设置里随时切 |

### 图库与导入

| 功能 | 说明 |
|---|---|
| **放大** | 三条路:NAI 传统超分(4×)· V5 扩散超分(2×)· 重绘放大(图生图,倍率与强度可调) |
| **参数导入** | 从 PNG 还原完整生成参数,**逐项可选**;认 NAI 的隐写元数据,也认 ComfyUI / A1111 的图(跨家族时只放行提示词,并把 a1111 权重语法转成 NAI 方言) |
| **「用作」** | 任意一张图直接用作图生图底图 / Vibe / 角色参考 |
| **手势** | 胶片条按住抬起拖去垃圾条即删,网格多选批量分享 / 保存 / 删除 |
| **工具箱** | 权重转换(SD ⇄ NAI 语法整串互转,结果带权重高亮,可一键导入创作页)、图片元数据查看与改写 |
| **从网页版迁移** | 导入 `novelai_web_ui` 的备份文件,Vibe / 角色参考 / OC / 画师串一次全部落位 |

### 账号与设置

| 功能 | 说明 |
|---|---|
| **两种登录** | 粘贴 Token,或用 NAI **账号密码**登录 —— 密码在本机 Argon2id 派生 access key,**不出设备、不落盘**,与官网网页端同一套零知识算法 |
| **用量统计** | 直连模式在本机按天记账(张数 / 免费张 / 点数),时间范围 + 趋势图 + 六格指标 + 日详情 |
| **外观与触感** | 深浅模式跟随系统、主题色可选、振动反馈开关 |
| **生成设置** | 完成通知、限流后自动重试(间隔与次数)、图库默认保存格式与元数据策略、创作页模块显隐与排序 |
| **存储管理** | 分类占用统计与逐项清理;二进制内容寻址去重 + 启动期 GC |
| **检查更新** | 只比对 GitHub Releases 并提示,下载与安装交给浏览器和系统 —— **不申请安装权限**,不自行安装任何东西 |

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
