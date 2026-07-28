import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'upscale_model_store.dart';

const _channel = MethodChannel('plana/upscale');

/// 本地超分(Real-ESRGAN ncnn-vulkan,native)。源图 PNG → (超分 PNG, 耗时 ms, 宽, 高)。
/// native 在**后台线程**跑(不阻塞 UI);PNG 解码/编码也在 native(stb)。
/// 模型不随包分发,首次使用时从上游下载,见 [ensureUpscaleModel]。
///
/// [model]:ncnn 模型名,默认轻量快速档。
/// [onStage]:阶段文案(下载模型 / 超分中…)。
/// [onProgress]:0~1 进度。模型下载阶段是下载比例,超分阶段是 tile 比例
/// (native 每完成一个 tile 经 MethodChannel `progress` 回报)。
Future<({Uint8List png, int ms, int width, int height})> upscaleLocal(
  Uint8List srcPng, {
  void Function(String stage)? onStage,
  void Function(double frac)? onProgress,
  String model = 'upscayl-lite-4x',
}) async {
  final sw = Stopwatch()..start();
  onStage?.call('准备模型…');
  final (param, bin) = await ensureUpscaleModel(
    model,
    onStage: onStage,
    onProgress: onProgress,
  );
  // 下载阶段刚把进度推到 1,超分阶段要从头再来一遍 —— 不清掉就会看到进度条
  // 满了又跳回去。null = 不确定态,等 native 的第一个 tile 回报再变确定。
  onProgress?.call(0);

  // 接收 native 按 tile 回报的进度(见 MainActivity 里 "progress" 的转发)。
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'progress') {
      final args = (call.arguments as Map).cast<String, dynamic>();
      final cur = (args['cur'] as num?)?.toInt() ?? 0;
      final total = (args['total'] as num?)?.toInt() ?? 0;
      if (total > 0) onProgress?.call((cur / total).clamp(0.0, 1.0));
    }
    return null;
  });

  onStage?.call('超分中(Vulkan GPU)…');
  try {
    final out = await _channel.invokeMethod<Uint8List>('upscale', {
      'png': srcPng,
      'param': param,
      'bin': bin,
      'scale': 4,
      'tile': 200,
      'prepadding': 10,
    });
    sw.stop();
    if (out == null || out.isEmpty) throw Exception('超分失败(native 返回空)');
    final (w, h) = _pngSize(out);
    return (png: out, ms: sw.elapsedMilliseconds, width: w, height: h);
  } finally {
    _channel.setMethodCallHandler(null);
  }
}

/// 从 PNG IHDR 读宽高(8 签名 + 8 chunk 头后是 4B 宽 + 4B 高)。
(int, int) _pngSize(Uint8List png) {
  if (png.length < 24) return (0, 0);
  final bd = ByteData.sublistView(png);
  return (bd.getUint32(16, Endian.big), bd.getUint32(20, Endian.big));
}
