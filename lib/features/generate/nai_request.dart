import 'dart:convert';
import 'dart:math';

import 'models.dart';
import 'prompt_presets.dart' show ucPresetDirect;

/// UI 展示名 → NAI 模型 id
const _modelMap = <String, String>{
  'NAI 4.5 Full': 'nai-diffusion-4-5-full',
  'NAI 4.5 Curated': 'nai-diffusion-4-5-curated',
  'NAI 4.0 Full': 'nai-diffusion-4-full',
  'NAI 4.0 Curated': 'nai-diffusion-4-curated-preview',
};

/// UI 展示名 → NAI 模型 id(编码 vibe 时也要用同一 id)。
String naiModelId(String displayModel) =>
    _modelMap[displayModel] ?? 'nai-diffusion-4-5-full';

/// 生成模型 id → inpainting 模型 id(对齐 web 后端:v3 特例,其余直接拼接)。
String inpaintModelId(String modelId) => modelId == 'nai-diffusion-3'
    ? 'nai-diffusion-3-inpainting'
    : '$modelId-inpainting';

/// UI 展示名 → NAI 采样器串(bot 模式构造 web 参数时复用同一映射)。
String naiSamplerId(String displaySampler) =>
    _samplerMap[displaySampler] ?? 'k_euler_ancestral';

/// 一个已编码的 vibe 参考:编码串 + 参考强度。
typedef EncodedVibe = ({String encoded, double strength});

/// 图生图参考:已 cover 到目标分辨率的 PNG base64 + 强度 + 噪声。
typedef Img2ImgRef = ({String image, double strength, double noise});

/// 一个待发的角色参考:已 contain 处理的 PNG base64 + 模式串 + 强度 + 保真度。
typedef CharRefPayload = ({
  String image,
  String mode,
  double strength,
  double fidelity,
});

/// UI 展示名 → NAI 采样器串
const _samplerMap = <String, String>{
  'Euler Ancestral': 'k_euler_ancestral',
  'Euler': 'k_euler',
  'DPM++ 2S A': 'k_dpmpp_2s_ancestral',
  'DPM++ 2M SDE': 'k_dpmpp_2m_sde',
  'DPM++ 2M': 'k_dpmpp_2m',
  'DPM++ SDE': 'k_dpmpp_sde',
};

/// AUTO(未指定站位)角色按序轮换的中心点(对齐 web `novelai.ts`,避免多角色叠在中心)。
const _autoCenters = <Map<String, double>>[
  {'x': 0.3, 'y': 0.5},
  {'x': 0.7, 'y': 0.5},
  {'x': 0.5, 'y': 0.3},
  {'x': 0.5, 'y': 0.7},
  {'x': 0.3, 'y': 0.3},
  {'x': 0.7, 'y': 0.7},
];

/// 角色中心点:有站位('A1'..'E5',列 A-E×行 1-5)→ `((col+.5)/5,(row-.5)/5)`;
/// AUTO → 按角色序 [index] 轮换 [_autoCenters]。与 web `novelai.ts` 一致。
Map<String, double> _center(String? pos, int index) {
  if (pos != null && pos.length >= 2) {
    final col = 'ABCDE'.indexOf(pos[0]);
    if (col >= 0) {
      final row = int.tryParse(pos.substring(1)) ?? 3;
      return {
        'x': double.parse(((col + 0.5) / 5).toStringAsFixed(4)),
        'y': double.parse(((row.clamp(1, 5) - 0.5) / 5).toStringAsFixed(4)),
      };
    }
  }
  return _autoCenters[index % _autoCenters.length];
}

/// 由创作页状态构造 NAI `/ai/generate-image-stream` 请求体(镜像 web `services/novelai.ts`)。
/// 返回体 + 实际使用的种子(留空随机时也已定值,便于图库回显)。已覆盖:
/// 文生图 + 多角色带位置 + Vibe + 图生图 + 角色参考(4.5)+ 重绘(infill)。
({Map<String, dynamic> body, int seed}) buildNaiPayload(
  GenerateState s, {
  required String presetId,
  List<EncodedVibe> vibes = const [],
  Img2ImgRef? img2img,
  List<CharRefPayload> charRefs = const [],
}) {
  final p = s.params;
  final inpaint = s.inpaint;
  final model = naiModelId(p.model);
  final sampler = _samplerMap[p.sampler] ?? 'k_euler_ancestral';
  final isV4 = model.startsWith('nai-diffusion-4');

  final seedStr = p.seed.trim();
  final seed = seedStr.isEmpty
      ? Random().nextInt(4294967296)
      : (int.tryParse(seedStr) ?? Random().nextInt(4294967296));

  // 仅启用且有正向内容的角色参与
  final chars = s.characters
      .where((c) => c.enabled && c.positive.trim().isNotEmpty)
      .toList();
  // web: use_coords = 有启用角色即 true(不看是否指定站位)
  final useCoords = chars.isNotEmpty;
  final centers = [
    for (var i = 0; i < chars.length; i++) _center(chars[i].position, i),
  ];

  final params = <String, dynamic>{
    'params_version': 3,
    'width': p.width,
    'height': p.height,
    'scale': p.cfg,
    'sampler': sampler,
    'steps': p.steps,
    'n_samples': 1,
    // 数值映射对齐 web UC_PRESET_MAP;预设正/负前缀已在 controller 拼进 s
    'ucPreset': ucPresetDirect(presetId),
    'qualityToggle': presetId == 'heavy',
    'autoSmea': false,
    'dynamic_thresholding': false,
    'controlnet_strength': 1,
    'legacy': false,
    'add_original_image': true,
    'cfg_rescale': p.cfgRescale,
    'noise_schedule': p.noiseSchedule,
    'legacy_v3_extend': false,
    // Variety+ = 固定值 58(与 web 一致),关闭则 null
    'skip_cfg_above_sigma': p.varietyPlus ? 58 : null,
    'use_coords': useCoords,
    'normalize_reference_strength_multiple': true,
    'inpaintImg2ImgStrength': 1,
    'seed': seed,
    'legacy_uc': false,
    'negative_prompt': s.negativePrompt,
    'deliberate_euler_ancestral_bug': false,
    'prefer_brownian': true,
    'image_format': 'png',
    'stream': 'msgpack',
  };

  // v4/v4.5 专属的结构化提示词;v3 走经典字段即可。
  if (isV4) {
    params['v4_prompt'] = {
      'caption': {
        'base_caption': s.prompt,
        'char_captions': [
          for (var i = 0; i < chars.length; i++)
            {
              'char_caption': chars[i].positive.trim(),
              'centers': [centers[i]],
            },
        ],
      },
      'use_coords': useCoords,
      'use_order': true,
    };
    params['v4_negative_prompt'] = {
      'caption': {
        'base_caption': s.negativePrompt,
        // 仅对负向非空的角色加(与 web 一致)
        'char_captions': [
          for (var i = 0; i < chars.length; i++)
            if (chars[i].negative.trim().isNotEmpty)
              {
                'char_caption': chars[i].negative.trim(),
                'centers': [centers[i]],
              },
        ],
      },
      'legacy_uc': false,
    };
    params['characterPrompts'] = [
      for (var i = 0; i < chars.length; i++)
        {
          'enabled': true,
          'prompt': chars[i].positive.trim(),
          'uc': chars[i].negative.trim(),
          'center': centers[i],
        },
    ];
  }

  // Vibe 参考:编码串 + 强度。与 web 一致:数量>1 且 和>1 时按比例归一化
  // (另有 normalize_reference_strength_multiple:true 兜底)。生成不发 info_extracted。
  if (vibes.isNotEmpty) {
    var strengths = [for (final v in vibes) v.strength];
    if (strengths.length > 1) {
      final total = strengths.fold<double>(0, (a, b) => a + b);
      if (total > 1) strengths = [for (final v in strengths) v / total];
    }
    params['reference_image_multiple'] = [for (final v in vibes) v.encoded];
    params['reference_strength_multiple'] = strengths;
  }

  // 角色参考(Director/Precise Reference):仅 4.5 模型下发,其余静默不发。
  // 五个并列数组;information_extracted 恒 1;secondary_strength = 1 - fidelity。
  if (charRefs.isNotEmpty && crSupportsModel(p.model)) {
    params['director_reference_images'] = [for (final c in charRefs) c.image];
    params['director_reference_descriptions'] = [
      for (final c in charRefs)
        {
          'caption': {'base_caption': c.mode, 'char_captions': <dynamic>[]},
          'legacy_uc': false,
        },
    ];
    params['director_reference_information_extracted'] = [
      for (final _ in charRefs) 1,
    ];
    params['director_reference_strength_values'] = [
      for (final c in charRefs) c.strength,
    ];
    params['director_reference_secondary_strength_values'] = [
      for (final c in charRefs) 1 - c.fidelity,
    ];
  }

  // 重绘(infill):底图+黑白 mask(白=重绘),模型换 -inpainting;
  // 与图生图互斥且优先(对齐 web 后端 convert_web_params_to_stream)。
  if (inpaint != null) {
    params['image'] = base64Encode(inpaint.image);
    params['mask'] = base64Encode(inpaint.mask);
    params['strength'] = inpaint.strength;
    params['noise'] = 0;
    params['extra_noise_seed'] = seed;
  } else if (img2img != null) {
    // 图生图:action 改 img2img,底图(已 cover 到目标分辨率)+ 强度/噪声/噪声种子。
    params['image'] = img2img.image;
    params['strength'] = img2img.strength;
    params['noise'] = img2img.noise;
    params['extra_noise_seed'] = seed;
  }

  final body = <String, dynamic>{
    'input': s.prompt,
    'model': inpaint != null ? inpaintModelId(model) : model,
    'action': inpaint != null
        ? 'infill'
        : (img2img != null ? 'img2img' : 'generate'),
    'use_new_shared_trial': true,
    'parameters': params,
  };
  return (body: body, seed: seed);
}
