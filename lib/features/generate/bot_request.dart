import 'dart:convert';

import 'models.dart';
import 'nai_request.dart'
    show
        CharRefPayload,
        Img2ImgRef,
        naiModelId,
        naiSamplerId,
        normalizeVibeStrengths;
import 'prompt_presets.dart' show ucPresetBot;

/// bot 模式的一条 vibe:后端编码串 + 强度 + 信息提取(原样透传,归一化交后端)。
typedef BotVibe = ({String encodedVibe, double strength, double infoExtracted});

/// Krea 风格参考:已下采样并编码好的一张图(base64,不带 data: 前缀)。
typedef KreaStyleRefPayload = String;

/// 由创作页状态构造后端 `POST /api/bot/generate` 的 `params`(web camelCase)。
/// 目标形状见后端 `convert_web_params_to_stream`。
///
/// 覆盖:文生图 + 多角色(带站位) + 角色参考 CR(仅 4.5) + 图生图 + Vibe + 重绘。
Map<String, dynamic> buildBotParams(
  GenerateState s, {
  required int seed,
  required String presetId,
  Img2ImgRef? img2img,
  List<CharRefPayload> charRefs = const [],
  List<BotVibe> vibes = const [],
  List<KreaStyleRefPayload> kreaStyleRefs = const [],
}) {
  final p = s.params;
  final model = naiModelId(p.model);
  final is45 = crSupportsModel(p.model);

  final chars = s.characters
      .where((c) => c.enabled && c.positive.trim().isNotEmpty)
      .toList();

  final params = <String, dynamic>{
    'positivePrompt': s.prompt,
    'negativePrompt': s.negativePrompt,
    'width': p.width,
    'height': p.height,
    'seed': seed,
    'steps': p.steps,
    'scale': p.cfg,
    'sampler': naiSamplerId(p.sampler),
    'cfgRescale': p.cfgRescale,
    'noiseSchedule': p.noiseSchedule,
    'varietyPlus': p.varietyPlus,
    'qualityToggle': presetId == 'heavy',
    'ucPreset': ucPresetBot(presetId), // 数值映射对齐 web bot 线 ucPresetMap
    'normalizeVibeStrength': p.normalizeVibe,
    'model': model, // 后端接受 API 内部名,直接透传
    'characterPrompts': [
      for (final c in chars)
        {
          'enabled': true,
          'positive': c.positive.trim(),
          'negative': c.negative.trim(),
          'position': c.position ?? '',
        },
    ],
  };

  // 角色参考(CR / Precise Reference):仅 4.5;后端算 secondary = 1 - informationExtracted
  if (charRefs.isNotEmpty && is45) {
    params['preciseReferences'] = [
      for (final c in charRefs)
        {
          'imageBase64': c.image,
          'mode': c.mode,
          'strength': c.strength,
          'informationExtracted': c.fidelity,
        },
    ];
  }

  // 重绘:后端识别 inpaint 块自动置 action=infill 并切 -inpainting 模型;
  // 与图生图互斥且优先(对齐后端 convert_web_params_to_stream 的处理顺序)。
  final inpaint = s.inpaint;
  if (inpaint != null) {
    params['inpaint'] = {
      'imageBase64': base64Encode(inpaint.image),
      'maskBase64': base64Encode(inpaint.mask),
      'strength': inpaint.strength,
      'noise': 0,
    };
  } else if (img2img != null) {
    // 图生图
    params['img2img'] = {
      'imageBase64': img2img.image,
      'strength': img2img.strength,
      'noise': img2img.noise,
    };
  }

  // Vibe:强度在这边算好再发。后端只是把 normalizeVibeStrength 转成
  // normalize_reference_strength_multiple 原样递给 NAI,自己不动强度,
  // 而 NAI 那个开关对直传编码串不生效 —— 不在这儿归一化就等于没这功能。
  if (vibes.isNotEmpty) {
    final strengths = normalizeVibeStrengths([
      for (final v in vibes) v.strength,
    ], on: p.normalizeVibe);
    params['vibeReferences'] = [
      for (var i = 0; i < vibes.length; i++)
        {
          'encodedVibe': vibes[i].encodedVibe,
          'strength': strengths[i],
          'informationExtracted': vibes[i].infoExtracted,
        },
    ];
  }

  // Anima / Krea:snake_case 对齐服务端 req.params.get("anima_extra" / "krea_extra")。
  // 两边后端都只读 正负词+尺寸+seed+各自的 extra,其余 NAI 参数被忽略
  // (NAI 专属数据已在剥离层清掉,此处无需重复处理)。
  //
  // 挂载的 LoRA(仅启用的,防御性截到服务端上限)。触发词由卡片点击直接写进
  // 正向词,这里显式传空数组告知服务端不要再拼(空数组=一个都不拼;LoRA 本体
  // name/weight 照常注入 LoraLoader 链)。pending(还在下载)的一律不发:机房里
  // 根本没有这个文件,发过去服务端查无此 LoRA 会静默丢弃,等于白跑一次生成。
  // 装好会就地转正,那之后才进载荷。两个渠道语义完全一致,故共用这一份。
  List<Map<String, dynamic>> loraPayload() => [
    for (final l
        in s.loras
            .where((l) => l.enabled && l.pending == null)
            .take(kMaxActiveLoras))
      {
        'name': l.name,
        'weight': l.weight,
        // 没单独设过(或该 LoRA 压根没有文本编码器权重)就不发,
        // 让服务端按「跟随 weight」处理
        if (l.clipWeight != null && l.hasTe != false)
          'clip_weight': l.clipWeight,
        'triggers': const <String>[],
      },
  ];

  if (isAnimaModel(p.model)) {
    final tier = animaTierOf(p.model);
    final loras = loraPayload();
    // 重绘放大:服务端据此注入 320+ 二段采样节点链。steps 省略 = 跟随主步数
    // (服务端读一段 KSampler 的 steps),所以 0 不发键而不是发 0。
    final hires = p.hires;
    params['anima_extra'] = {
      'steps': p.animaSteps,
      'cfg': p.animaCfg,
      'sampler': p.animaSampler,
      'scheduler': p.animaScheduler,
      'model': tier,
      'turbo': tier == 'turbo',
      // 一次出几张。发 `effectiveBatch` 而不是用户选的那个数:开着重绘放大时
      // 服务端会强制单张,这里跟着发 1,免得界面上摆着「×4」而实际只出一张。
      'batch_size': p.effectiveBatch,
      if (loras.isNotEmpty) 'loras': loras,
      if (hires.enabled)
        'hires': {
          'scale': hires.scale,
          'denoise': hires.denoise,
          if (hires.steps > 0) 'steps': hires.steps,
          'upscaler': hires.upscalerKey,
        },
    };
  } else if (isKreaModel(p.model)) {
    // krea 走 krea_extra,不传 anima_extra:两边字段集不同(这边没有 hires),
    // 混传只会让服务端困惑。
    // sampler/scheduler 白名单外的值服务端静默回退档位默认,不报错。
    final loras = loraPayload();
    params['krea_extra'] = {
      'steps': p.kreaSteps,
      'cfg': p.kreaCfg,
      'sampler': p.kreaSampler,
      'scheduler': p.kreaScheduler,
      'model': kreaTierOf(p.model),
      'batch_size': p.effectiveBatch,
      if (loras.isNotEmpty) 'loras': loras,
      // 风格参考:raw 档不拦(用户想试就让他试),服务端会回一条 warning ——
      // 卡片上也已经就地提示过了。
      if (kreaStyleRefs.isNotEmpty)
        'style_ref': {
          'imagesBase64': kreaStyleRefs,
          'weight': s.kreaStyleRefWeight,
        },
    };
  }

  return params;
}
