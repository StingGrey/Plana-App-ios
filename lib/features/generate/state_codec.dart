import 'dart:typed_data';

import '../../core/store/blob_store.dart';
import 'models.dart';

/// GenerateState ⇄ JSON。图片字节不进 JSON——写入 [BlobStore] 后只存
/// 内容哈希引用;[EncodedState.refs] 汇总本快照引用的全部 blob,
/// 落盘方把它写进信封顶层,启动期 GC 只扫信封不解析业务字段。
class EncodedState {
  const EncodedState(this.json, this.refs);

  final Map<String, dynamic> json;
  final Set<String> refs;
}

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

Future<EncodedState> encodeGenerateState(
  GenerateState s,
  BlobStore blobs,
) async {
  final refs = <String>{};

  Future<String?> putImg(Uint8List? bytes, {String? known}) async {
    if (bytes == null) return null;
    final h = await blobs.put(bytes, known: known);
    refs.add(h);
    return h;
  }

  final vibes = <Map<String, dynamic>>[];
  for (final v in s.vibes) {
    vibes.add({
      'id': v.id,
      'name': v.name,
      'enabled': v.enabled,
      'strength': v.strength,
      'infoExtracted': v.infoExtracted,
      'image': await putImg(v.image, known: v.imageHash),
      if (v.encodedByModel != null) 'encodedByModel': v.encodedByModel,
      if (v.sourceId != null) 'sourceId': v.sourceId,
    });
  }

  final charRefs = <Map<String, dynamic>>[];
  for (final r in s.charRefs) {
    charRefs.add({
      'id': r.id,
      'name': r.name,
      'enabled': r.enabled,
      'mode': r.mode.name,
      'strength': r.strength,
      'infoExtracted': r.infoExtracted,
      'image': await putImg(r.image, known: r.imageHash),
    });
  }

  final i2i = s.img2img;
  final inpaint = s.inpaint;
  final paste = inpaint?.paste;
  final p = s.params;

  final json = <String, dynamic>{
    'prompt': s.prompt,
    'negativePrompt': s.negativePrompt,
    'characters': [
      for (final c in s.characters)
        {
          'id': c.id,
          'name': c.name,
          'positive': c.positive,
          'negative': c.negative,
          'enabled': c.enabled,
          if (c.position != null) 'position': c.position,
          'activeTab': c.activeTab.name,
        },
    ],
    'vibes': vibes,
    'charRefs': charRefs,
    if (i2i != null)
      'img2img': {
        'strength': i2i.strength,
        'noise': i2i.noise,
        'image': await putImg(i2i.image),
      },
    'params': {
      'model': p.model,
      'width': p.width,
      'height': p.height,
      'steps': p.steps,
      'cfg': p.cfg,
      'varietyPlus': p.varietyPlus,
      'sampler': p.sampler,
      'noiseSchedule': p.noiseSchedule,
      'seed': p.seed,
      'cfgRescale': p.cfgRescale,
      'loop': p.loop.name,
      'animaSteps': p.animaSteps,
      'animaCfg': p.animaCfg,
      'animaSampler': p.animaSampler,
      'animaScheduler': p.animaScheduler,
    },
    'anlas': s.anlas,
    'openPanels': [for (final pn in s.openPanels) pn.name],
    if (inpaint != null)
      'inpaint': {
        'image': await putImg(inpaint.image),
        'mask': await putImg(inpaint.mask),
        'strength': inpaint.strength,
        if (paste != null)
          'paste': {
            'original': await putImg(paste.original),
            'sendX': paste.sendX,
            'sendY': paste.sendY,
            'tightX': paste.tightX,
            'tightY': paste.tightY,
            'tightW': paste.tightW,
            'tightH': paste.tightH,
            'outW': paste.outW,
            'outH': paste.outH,
          },
      },
  };
  return EncodedState(json, refs);
}

/// 反序列化。blob 缺失(被清/损坏)时按条目降级:vibe 留编码丢图、
/// CR 整条跳过、img2img/重绘任务置空——恢复出的状态始终可用。
Future<GenerateState> decodeGenerateState(
  Map<String, dynamic> j,
  BlobStore blobs,
) async {
  Future<Uint8List?> img(Object? hash) async =>
      hash is String && hash.isNotEmpty ? blobs.get(hash) : null;

  final characters = <CharacterPrompt>[];
  if (j['characters'] is List) {
    for (final e in j['characters'] as List) {
      if (e is! Map) continue;
      final id = e['id'];
      if (id is! String) continue;
      characters.add(CharacterPrompt(
        id: id,
        name: e['name'] is String ? e['name'] as String : '角色',
        positive: e['positive'] is String ? e['positive'] as String : '',
        negative: e['negative'] is String ? e['negative'] as String : '',
        enabled: e['enabled'] != false,
        position: e['position'] as String?,
        activeTab:
            _enumByName(CharTab.values, e['activeTab']) ?? CharTab.positive,
      ));
    }
  }

  final vibes = <VibeItem>[];
  if (j['vibes'] is List) {
    for (final e in j['vibes'] as List) {
      if (e is! Map) continue;
      final id = e['id'];
      if (id is! String) continue;
      final hash = e['image'] as String?;
      final bytes = await img(hash);
      final enc = e['encodedByModel'] is Map
          ? (e['encodedByModel'] as Map).map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            )
          : null;
      if (bytes == null && (enc == null || enc.isEmpty)) continue; // 不可生成
      vibes.add(VibeItem(
        id: id,
        name: e['name'] is String ? e['name'] as String : '',
        enabled: e['enabled'] != false,
        strength: (e['strength'] as num?)?.toDouble() ?? 0.6,
        infoExtracted: (e['infoExtracted'] as num?)?.toDouble() ?? 1.0,
        image: bytes,
        imageHash: bytes != null ? hash : null,
        encodedByModel: enc,
        sourceId: e['sourceId'] as String?,
      ));
    }
  }

  final charRefs = <CharRefItem>[];
  if (j['charRefs'] is List) {
    for (final e in j['charRefs'] as List) {
      if (e is! Map) continue;
      final id = e['id'];
      if (id is! String) continue;
      final hash = e['image'] as String?;
      final bytes = await img(hash);
      if (bytes == null) continue; // 无图的 CR 无法参与生成
      charRefs.add(CharRefItem(
        id: id,
        name: e['name'] is String ? e['name'] as String : '',
        enabled: e['enabled'] != false,
        mode: _enumByName(CharRefMode.values, e['mode']) ?? CharRefMode.both,
        strength: (e['strength'] as num?)?.toDouble() ?? 1.0,
        infoExtracted: (e['infoExtracted'] as num?)?.toDouble() ?? 1.0,
        image: bytes,
        imageHash: hash,
      ));
    }
  }

  Img2ImgConfig? img2img;
  if (j['img2img'] is Map) {
    final e = j['img2img'] as Map;
    final bytes = await img(e['image']);
    if (bytes != null) {
      img2img = Img2ImgConfig(
        strength: (e['strength'] as num?)?.toDouble() ?? 0.7,
        noise: (e['noise'] as num?)?.toDouble() ?? 0.0,
        image: bytes,
      );
    }
  }

  var params = const GenParams();
  if (j['params'] is Map) {
    final e = j['params'] as Map;
    params = GenParams(
      model: e['model'] is String ? e['model'] as String : params.model,
      width: (e['width'] as num?)?.toInt() ?? params.width,
      height: (e['height'] as num?)?.toInt() ?? params.height,
      steps: (e['steps'] as num?)?.toInt() ?? params.steps,
      cfg: (e['cfg'] as num?)?.toDouble() ?? params.cfg,
      varietyPlus: e['varietyPlus'] == true,
      sampler: e['sampler'] is String ? e['sampler'] as String : params.sampler,
      noiseSchedule: e['noiseSchedule'] is String
          ? e['noiseSchedule'] as String
          : params.noiseSchedule,
      seed: e['seed'] is String ? e['seed'] as String : '',
      cfgRescale: (e['cfgRescale'] as num?)?.toDouble() ?? 0.0,
      loop: _enumByName(LoopCount.values, e['loop']) ?? LoopCount.x8,
      animaSteps: (e['animaSteps'] as num?)?.toInt() ?? params.animaSteps,
      animaCfg: (e['animaCfg'] as num?)?.toDouble() ?? params.animaCfg,
      animaSampler: e['animaSampler'] is String
          ? e['animaSampler'] as String
          : params.animaSampler,
      animaScheduler: e['animaScheduler'] is String
          ? e['animaScheduler'] as String
          : params.animaScheduler,
    );
  }

  InpaintJob? inpaint;
  if (j['inpaint'] is Map) {
    final e = j['inpaint'] as Map;
    final image = await img(e['image']);
    final mask = await img(e['mask']);
    if (image != null && mask != null) {
      InpaintPaste? paste;
      if (e['paste'] is Map) {
        final pe = e['paste'] as Map;
        final original = await img(pe['original']);
        if (original != null) {
          paste = InpaintPaste(
            original: original,
            sendX: (pe['sendX'] as num?)?.toInt() ?? 0,
            sendY: (pe['sendY'] as num?)?.toInt() ?? 0,
            tightX: (pe['tightX'] as num?)?.toInt() ?? 0,
            tightY: (pe['tightY'] as num?)?.toInt() ?? 0,
            tightW: (pe['tightW'] as num?)?.toInt() ?? 0,
            tightH: (pe['tightH'] as num?)?.toInt() ?? 0,
            outW: (pe['outW'] as num?)?.toInt() ?? 0,
            outH: (pe['outH'] as num?)?.toInt() ?? 0,
          );
        }
      }
      inpaint = InpaintJob(image: image, mask: mask,
          strength: (e['strength'] as num?)?.toDouble() ?? 0.7, paste: paste);
    }
  }

  final openPanels = <Panel>{};
  if (j['openPanels'] is List) {
    for (final n in j['openPanels'] as List) {
      final p = _enumByName(Panel.values, n);
      if (p != null) openPanels.add(p);
    }
  }

  return GenerateState(
    prompt: j['prompt'] is String ? j['prompt'] as String : '',
    negativePrompt:
        j['negativePrompt'] is String ? j['negativePrompt'] as String : '',
    characters: characters,
    vibes: vibes,
    charRefs: charRefs,
    img2img: img2img,
    params: params,
    anlas: (j['anlas'] as num?)?.toInt() ?? 0,
    openPanels: openPanels,
    inpaint: inpaint,
  );
}
