// ComfyUI 元数据解析:必须按图走,不能遍历节点碰运气。
//
// 三条护栏对应三个真实翻车点:正向里出现 "bad" 会被关键词猜法整段判成负向;
// 带 hires fix 的图有两段 KSampler,遍历会取到随机一段;LoRA 是节点不是文本标签。
// 用例图取自我们自己的 Anima 工作流(server/data/anima_base_api.json 同构)。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/import/image_metadata.dart';

/// 最小可用 PNG:只要 tEXt 块能被扫到即可,像素内容无所谓。
Uint8List pngWithText(Map<String, String> texts) {
  final crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  int crc32(List<int> bytes) {
    var c = 0xffffffff;
    for (final b in bytes) {
      c = crcTable[(c ^ b) & 0xff] ^ (c >> 8);
    }
    return (c ^ 0xffffffff) & 0xffffffff;
  }

  List<int> chunk(String type, List<int> data) {
    final len = ByteData(4)..setUint32(0, data.length);
    final body = [...utf8.encode(type), ...data];
    final crc = ByteData(4)..setUint32(0, crc32(body));
    return [...len.buffer.asUint8List(), ...body, ...crc.buffer.asUint8List()];
  }

  final ihdr = ByteData(13)
    ..setUint32(0, 4)
    ..setUint32(4, 4)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final idat = ZLibCodec().encode(List<int>.filled(4 * (1 + 16), 0));

  return Uint8List.fromList([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ...chunk('IHDR', ihdr.buffer.asUint8List()),
    for (final e in texts.entries)
      ...chunk('tEXt', [...latin1.encode(e.key), 0, ...latin1.encode(e.value)]),
    ...chunk('IDAT', idat),
    ...chunk('IEND', const []),
  ]);
}

Map<String, dynamic> animaGraph() => {
  '44': {
    'class_type': 'UNETLoader',
    'inputs': {'unet_name': 'anima-turbo-v1.0.safetensors'},
  },
  '45': {
    'class_type': 'CLIPLoader',
    'inputs': {'clip_name': 'qwen_3_06b_base.safetensors'},
  },
  '100': {
    'class_type': 'LoraLoader',
    'inputs': {
      'lora_name': 'anima-turbo-lora-v0.2.safetensors',
      'strength_model': 0.0,
      'model': ['44', 0],
      'clip': ['45', 0],
    },
  },
  '101': {
    'class_type': 'LoraLoader',
    'inputs': {
      'lora_name': 'anima-highres-aesthetic-boost.safetensors',
      'strength_model': 0.0,
      'model': ['100', 0],
      'clip': ['100', 1],
    },
  },
  '28': {
    'class_type': 'EmptyLatentImage',
    'inputs': {'width': 832, 'height': 1216, 'batch_size': 1},
  },
  '11': {
    'class_type': 'CLIPTextEncode',
    'inputs': {
      'clip': ['101', 1],
      'text': 'masterpiece, 1girl, miko, cherry blossoms',
    },
  },
  '12': {
    'class_type': 'CLIPTextEncode',
    'inputs': {
      'clip': ['101', 1],
      'text': 'worst quality, low quality, blurry',
    },
  },
  '19': {
    'class_type': 'KSampler',
    'inputs': {
      'model': ['101', 0],
      'positive': ['11', 0],
      'negative': ['12', 0],
      'latent_image': ['28', 0],
      'seed': 123456,
      'steps': 12,
      'cfg': 1.0,
      'sampler_name': 'euler',
      'scheduler': 'simple',
    },
  },
  '8': {
    'class_type': 'VAEDecode',
    'inputs': {
      'samples': ['19', 0],
      'vae': ['15', 0],
    },
  },
  '46': {
    'class_type': 'SaveImage',
    'inputs': {
      'images': ['8', 0],
    },
  },
};

Future<ImageMetadata?> parseGraph(Map<String, dynamic> graph) =>
    extractImageMetadata(pngWithText({'prompt': jsonEncode(graph)}));

void main() {
  test('自己的 Anima 图逐字段还原', () async {
    final m = await parseGraph(animaGraph());
    expect(m, isNotNull);
    expect(m!.sourceType, ImageSourceType.comfyui);
    expect(m.promptSyntax, PromptSyntax.a1111);
    expect(m.source, 'anima-turbo-v1.0');
    expect(m.prompt, 'masterpiece, 1girl, miko, cherry blossoms');
    expect(m.negativePrompt, 'worst quality, low quality, blurry');
    expect(m.width, 832);
    expect(m.height, 1216);
    expect(m.seed, '123456');
    expect(m.steps, '12');
    expect(m.scale, '1');
    expect(m.sampler, 'euler');
    expect(m.noiseSchedule, 'simple');
    // 两个内置 LoRA 强度都是 0 = 挂着没启用,不该算数
    expect(m.loras, isEmpty);
  });

  test('正向里含 bad 不会被判成负向(关键词猜法的老坑)', () async {
    final g = animaGraph();
    (g['11'] as Map)['inputs']['text'] = 'bad end avoided, 1girl, smile';
    final m = await parseGraph(g);
    expect(m!.prompt, 'bad end avoided, 1girl, smile');
    expect(m.negativePrompt, 'worst quality, low quality, blurry');
  });

  test('hires fix 两段 KSampler 取末段', () async {
    final g = animaGraph();
    (g['19'] as Map)['inputs']['steps'] = 8;
    g['30'] = {
      'class_type': 'LatentUpscale',
      'inputs': {
        'samples': ['19', 0],
        'width': 1664,
        'height': 2432,
      },
    };
    g['31'] = {
      'class_type': 'KSampler',
      'inputs': {
        'model': ['101', 0],
        'positive': ['11', 0],
        'negative': ['12', 0],
        'latent_image': ['30', 0],
        'seed': 999,
        'steps': 20,
        'cfg': 4.5,
        'sampler_name': 'dpmpp_2m',
        'scheduler': 'karras',
      },
    };
    (g['8'] as Map)['inputs']['samples'] = ['31', 0];

    final m = await parseGraph(g);
    expect(m!.seed, '999');
    expect(m.steps, '20');
    expect(m.scale, '4.5');
    expect(m.sampler, 'dpmpp_2m');
    expect(m.noiseSchedule, 'karras');
    expect(m.width, 1664);
    expect(m.height, 2432);
  });

  test('LoraLoader 链按加载顺序收集,滤掉强度 0', () async {
    final g = animaGraph();
    // 100 是模板内置的 anima-turbo-lora,恒被当基础设施剔掉(见下一条),
    // 这里换成一条用户 LoRA 才测得出「按加载顺序」
    (g['100'] as Map)['inputs']['lora_name'] = 'LR7.safetensors';
    (g['100'] as Map)['inputs']['strength_model'] = 0.8;
    (g['101'] as Map)['inputs']['strength_model'] = 0.35;
    final m = await parseGraph(g);
    expect(m!.loras.map((l) => l.name).toList(), [
      'LR7',
      'anima-highres-aesthetic-boost',
    ]);
    expect(m.loras.map((l) => l.weight).toList(), [0.8, 0.35]);
  });

  // 出图管线自己挂的权重不是用户选的:混进导入清单会显示一条他没挂过、
  // 库里也查不到的 LoRA。强度非 0 也照剔。
  test('基础设施 LoRA 一律不进导入清单,子目录名取 basename', () async {
    final g = animaGraph();
    (g['100'] as Map)['inputs']['lora_name'] =
        'krea/krea2_style_reference.safetensors';
    (g['100'] as Map)['inputs']['strength_model'] = 1.0;
    (g['101'] as Map)['inputs']['lora_name'] = 'krea/LR120.safetensors';
    (g['101'] as Map)['inputs']['strength_model'] = 0.7;
    final m = await parseGraph(g);
    // 只剩用户那条,且名字剥掉了 krea/ 前缀(LR 编号才是库里的键)
    expect(m!.loras.map((l) => l.name).toList(), ['LR120']);
    expect(m.loras.single.weight, 0.7);
  });

  test('数值来自 primitive 节点引用时也能解出', () async {
    final g = animaGraph();
    g['200'] = {
      'class_type': 'PrimitiveNode',
      'inputs': {'value': 42},
    };
    (g['19'] as Map)['inputs']['seed'] = ['200', 0];
    final m = await parseGraph(g);
    expect(m!.seed, '42');
  });

  test('解不出采样节点时不猜,留空但仍标 comfyui', () async {
    final m = await parseGraph({
      '1': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'orphan text'},
      },
    });
    expect(m!.sourceType, ImageSourceType.comfyui);
    expect(m.prompt, '');
    expect(m.width, 0);
  });
}
