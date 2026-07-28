# 第三方组件与许可

Plana 使用了下列第三方组件。BSD-3-Clause 等许可要求在分发时保留版权声明与免责条款,
本文件即为该声明的载体。

> 分发本应用(APK / 应用商店 / 侧载包)时,请连同本文件一并提供,或在应用内「关于」页
> 提供等效的开源许可入口。

---

## 原生组件(`android/app/src/main/cpp/`)

本地超分功能(离线 4× 放大)基于以下组件构建:

### ncnn
- 版权:Copyright (c) 2017 THL A29 Limited, a Tencent company
- 许可:BSD 3-Clause License
- 项目:https://github.com/Tencent/ncnn

### glslang
- 版权:Copyright (C) 2015-2020 Google, Inc. / The Khronos Group Inc. 等
- 许可:BSD 3-Clause License(含 Apache-2.0 / MIT 部分组件)
- 项目:https://github.com/KhronosGroup/glslang

### Real-ESRGAN ncnn Vulkan
- 版权:Copyright (c) 2021 Xintao Wang / nihui
- 许可:BSD 3-Clause License
- 项目:https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan

### stb_image / stb_image_write
- 作者:Sean Barrett
- 许可:MIT License 或 Public Domain(双许可,可任选)
- 项目:https://github.com/nothings/stb

---

## 模型权重 —— **本应用不分发**

超分模型不随安装包分发,也不经由本项目的任何服务器中转。首次使用某个本地
超分档位时,由**用户设备直接从 Upscayl 官方仓库下载**:

```
https://raw.githubusercontent.com/upscayl/upscayl/v2.15.0/resources/models/
```

| 模型 | 用途 |
|---|---|
| `upscayl-lite-4x` | 本地·快速档(≈ Real-ESRGAN animevideov3) |
| `digital-art-4x` | 本地·质量档 |

URL 钉在 tag `v2.15.0` 上,并对每个文件校验 SHA-256(清单见
`lib/features/gallery/upscale_model_store.dart`)。

> **为什么这么做**:Upscayl 的 AGPL-3.0 覆盖的是其应用代码,不是模型权重。
> `resources/models/` 目录下既无 LICENSE 也无 README,逐个模型的授权条款
> 上游从未写明;官方 discussion #1130 中维护者只确认过「导出的图片可商用」,
> **权重本身能否被第三方再分发没有答案**。因此本应用选择完全不接触权重的
> 分发链路 —— 用户从源站自取。

---

## Dart / Flutter 依赖

全部经 pub.dev 分发,许可均为宽松型(无 GPL 系):

| 许可 | 包 |
|---|---|
| BSD | `animations` · `crypto` · `flutter_secure_storage` · `gal` · `http` · `path_provider` · `url_launcher` |
| MIT | `archive` · `cupertino_icons` · `file_picker` · `flutter_riverpod` · `image` · `msgpack_dart` |
| Apache-2.0 | `material_color_utilities` · `photo_manager` · `photo_manager_image_provider` |

Flutter SDK 及其自带组件遵循 BSD 3-Clause(Copyright 2014 The Flutter Authors)。
完整的依赖许可清单可由 `flutter build` 生成的 `LICENSE` 汇总文件获得,
应用内亦可通过 `showLicensePage()` 展示。
