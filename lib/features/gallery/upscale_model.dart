import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/store/prefs_store.dart';

/// 超分方式:本地两档(ncnn-vulkan,免费/不限尺寸/离线)+ NAI 官方(远程,扣点/限尺寸)。
enum UpscaleMethod {
  /// 本地·快速(轻量 upscayl-lite,≈ Real-ESRGAN animevideov3)。
  localFast(
    label: '快速',
    desc: '本地轻量,速度优先',
    local: true,
    asset: 'upscayl-lite-4x',
    badge: '2.3MB',
  ),

  /// 本地·质量(upscayl digital-art,动漫画质更好、略慢)。
  localQuality(
    label: '质量',
    desc: '本地画质档,动漫更佳',
    local: true,
    asset: 'digital-art-4x',
    badge: '8.5MB',
  ),

  /// NAI 官方超分(远程 4×,仅限固定尺寸,固定扣 7 点——用户实测确认)。
  nai(
    label: 'NAI 超分',
    desc: '官方模型 · 7 点',
    local: false,
    asset: null,
    badge: '4×',
  ),

  /// NAI 图生图重绘放大(1.5×,会轻微改画面;走生成管线,扣点)。
  redraw15x(
    label: '1.5× 重绘',
    desc: '图生图重绘 · 略改画面',
    local: false,
    asset: null,
    badge: '1.5×',
  );

  const UpscaleMethod({
    required this.label,
    required this.desc,
    required this.local,
    required this.asset,
    required this.badge,
  });

  final String label;
  final String desc;

  /// true=本地 ncnn-vulkan;false=NAI 远程。
  final bool local;

  /// 本地模型名(见 `upscale_model_store.dart` 的清单);NAI 为 null。
  /// 模型不随包分发,首次使用时下载。
  final String? asset;

  /// 角标:本地显示模型的下载体积,NAI 显示倍率。
  final String badge;
}

/// NAI 官方超分支持的固定分辨率(其他尺寸后端直接拒)。
const naiUpscaleResolutions = <(int, int)>[
  (832, 1216),
  (1216, 832),
  (1024, 1024),
];

/// 当前尺寸能否走 NAI 超分。
bool naiUpscaleSupportsSize(int w, int h) =>
    naiUpscaleResolutions.contains((w, h));

/// 1.5× 重绘默认强度/噪声(对齐 web MAGNITUDE_PRESETS 档 3)。
const kRedraw15xStrength = 0.5;
const kRedraw15xNoise = 0.0;

/// 1.5× 重绘目标像素上限(对齐 web:1024×3072,与普通生成一致)。
const redraw15xMaxPixels = 1024 * 3072;

/// 当前尺寸能否走 1.5× 重绘(目标 = 原 ×1.5 对齐 64,不超上限)。
bool redraw15xSupportsSize(int w, int h) {
  final tw = ((w * 1.5) / 64).round() * 64;
  final th = ((h * 1.5) / 64).round() * 64;
  return tw > 0 && th > 0 && tw * th <= redraw15xMaxPixels;
}

const _key = 'upscale_method';

/// 用户选择的超分方式(持久化);默认 [UpscaleMethod.localFast]。
final upscaleMethodProvider =
    AsyncNotifierProvider<UpscaleMethodNotifier, UpscaleMethod>(
      UpscaleMethodNotifier.new,
    );

class UpscaleMethodNotifier extends AsyncNotifier<UpscaleMethod> {
  PrefsStore get _storage => ref.read(prefsStoreProvider);

  @override
  Future<UpscaleMethod> build() async {
    try {
      final v = await _storage.read(key: _key);
      return UpscaleMethod.values.firstWhere(
        (m) => m.name == v,
        orElse: () => UpscaleMethod.localFast,
      );
    } catch (_) {
      return UpscaleMethod.localFast;
    }
  }

  Future<void> set(UpscaleMethod m) async {
    try {
      await _storage.write(key: _key, value: m.name);
      state = AsyncData(m);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}
