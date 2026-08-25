# 第三方组件与许可

Plana 使用了下列第三方组件。相关许可要求在分发时保留版权声明与免责条款,
本文件即为该声明的载体。

> 1.0.6 起本地超分(ncnn-vulkan / Real-ESRGAN / stb / Upscayl 模型)整条下线,
> 相关组件与权重下载链路一并移除,故本文件不再列出它们。

> 分发本应用(APK / 应用商店 / 侧载包)时,请连同本文件一并提供,或在应用内「关于」页
> 提供等效的开源许可入口。

---

## Dart / Flutter 依赖

全部经 pub.dev 分发,许可均为宽松型(无 GPL 系):

| 许可 | 包 |
|---|---|
| BSD | `animations` · `crypto` · `flutter_secure_storage` · `gal` · `http` · `path_provider` · `share_plus` · `url_launcher` |
| MIT | `archive` · `file_picker` · `flutter_riverpod` · `image` · `msgpack_dart` · `unorm_dart` |
| Apache-2.0 | `cryptography` · `material_color_utilities` · `photo_manager` · `photo_manager_image_provider` |

Flutter SDK 及其自带组件遵循 BSD 3-Clause(Copyright 2014 The Flutter Authors)。
完整的依赖许可清单可由 `flutter build` 生成的 `LICENSE` 汇总文件获得,
应用内亦可通过 `showLicensePage()` 展示。

仅构建期使用、不进包的依赖(`flutter_lints`、`flutter_launcher_icons`)不在此列 ——
本文件是随包分发的声明载体,只覆盖真正打进 APK 的东西。

---

## 随包分发的数据文件

`assets/` 下有两份**非本项目创作**的数据,随 APK 一同分发:

| 文件 | 出处 | 许可 |
|---|---|---|
| `danbooru.tsv` | 标签表、热度与绝大部分中文译名取自 [zhulinyv/Auto-NovelAI-Refactor](https://github.com/zhulinyv/Auto-NovelAI-Refactor) 的 `assets/danbooru_e621_merged_with_zh.csv`;标签体系与别名归 [Danbooru](https://danbooru.donmai.us/) | 上游项目为 **GPL-3.0**,与本项目同许可,再分发合规 |
| `t5_tokenizer.json` | NovelAI 的 T5 分词器词表,字节级原样拷贝 | 版权归 Anlatan;本项目仅为 token 计数而调用,不作他用 |

法典图鉴(quicktagcloud)的数据**不随包分发**,运行时只读拉取,故不在此列。
