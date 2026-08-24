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
| BSD | `animations` · `crypto` · `flutter_secure_storage` · `gal` · `http` · `path_provider` · `url_launcher` |
| MIT | `archive` · `cupertino_icons` · `file_picker` · `flutter_riverpod` · `image` · `msgpack_dart` · `unorm_dart` |
| Apache-2.0 | `cryptography` · `material_color_utilities` · `photo_manager` · `photo_manager_image_provider` |

Flutter SDK 及其自带组件遵循 BSD 3-Clause(Copyright 2014 The Flutter Authors)。
完整的依赖许可清单可由 `flutter build` 生成的 `LICENSE` 汇总文件获得,
应用内亦可通过 `showLicensePage()` 展示。
