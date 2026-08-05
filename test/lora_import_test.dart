import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/features/import/image_metadata.dart';

/// 图片元数据里的 LoRA 认领依据:真名 + 哈希 + 双权重。
///
/// 这套东西的意义在于「换个部署/发给别人也认得出用了什么 LoRA」——
/// 工作流块里的 lora_name 只是内部编号(web/LRxx),离开本机就是一串废字符。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 拼一张最小合法 PNG,并塞入指定文本块。
  Uint8List pngWithChunks(Map<String, String> texts) {
    final out = BytesBuilder();
    out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

    void chunk(String type, List<int> data) {
      final t = ascii.encode(type);
      final len = ByteData(4)..setUint32(0, data.length);
      out.add(len.buffer.asUint8List());
      out.add(t);
      out.add(data);
      final crcInput = <int>[...t, ...data];
      final crc = ByteData(4)..setUint32(0, _crc32(crcInput));
      out.add(crc.buffer.asUint8List());
    }

    final ihdr = ByteData(13)
      ..setUint32(0, 1)
      ..setUint32(4, 1)
      ..setUint8(8, 8)
      ..setUint8(9, 0);
    chunk('IHDR', ihdr.buffer.asUint8List());
    // IDAT 内容不参与解析(只读文本块),给一段合法 zlib 空存储块即可
    chunk('IDAT', const [0x78, 0x01, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01]);
    for (final e in texts.entries) {
      // 中文要走 iTXt(UTF-8);keyword\0 压缩标志 压缩方法 语言\0 翻译关键字\0 文本
      chunk('iTXt', [
        ...ascii.encode(e.key),
        0, 0, 0, 0, 0,
        ...utf8.encode(e.value),
      ]);
    }
    chunk('IEND', const []);
    return out.toBytes();
  }

  const params = '1girl, solo <lora:某某画风 v2:0.8> <lora:角色A:0.65:0.4>\n'
      'Negative prompt: lowres\n'
      'Steps: 12, Sampler: euler, CFG scale: 1, Seed: 42, Size: 832x1216, '
      'Model: anima-base-v1.0, '
      'Lora hashes: "某某画风 v2: a1b2c3d4e5f6, 角色A: ffee00112233", '
      'Version: Plana-Anima';

  test('A1111 parameters:真名 / 哈希 / 双权重都解析得出来', () async {
    final meta = await extractImageMetadata(pngWithChunks({'parameters': params}));
    expect(meta, isNotNull);
    expect(meta!.loras.length, 2);

    expect(meta.loras[0].name, '某某画风 v2');
    expect(meta.loras[0].weight, 0.8);
    expect(meta.loras[0].clipWeight, isNull); // 单权重 → CLIP 跟随
    expect(meta.loras[0].hash, 'a1b2c3d4e5f6');

    expect(meta.loras[1].name, '角色A');
    expect(meta.loras[1].weight, 0.65);
    expect(meta.loras[1].clipWeight, 0.4); // 双权重 <名:unet:clip>
    expect(meta.loras[1].hash, 'ffee00112233');
  });

  test('两块并存时:参数取 ComfyUI,LoRA 取 A1111(真名+哈希,不是内部编号)', () async {
    // 自家出的图就是这样:SaveImage 写工作流块,server 另补 A1111 块
    final graph = jsonEncode({
      '11': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': '1girl, solo'},
      },
      '12': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'lowres'},
      },
      '19': {
        'class_type': 'KSampler',
        'inputs': {
          'steps': 12,
          'cfg': 1.0,
          'sampler_name': 'euler',
          'scheduler': 'simple',
          'seed': 42,
          'positive': ['11', 0],
          'negative': ['12', 0],
          'latent_image': ['28', 0],
          'model': ['200', 0],
        },
      },
      '28': {
        'class_type': 'EmptyLatentImage',
        'inputs': {'width': 832, 'height': 1216},
      },
      '44': {
        'class_type': 'UNETLoader',
        'inputs': {'unet_name': 'anima-base-v1.0.safetensors'},
      },
      '200': {
        'class_type': 'LoraLoader',
        'inputs': {
          'lora_name': 'web/LR23.safetensors', // ← 内部编号,不该外泄给用户
          'strength_model': 0.8,
          'model': ['44', 0],
        },
      },
    });

    final meta = await extractImageMetadata(
      pngWithChunks({'prompt': graph, 'parameters': params}),
    );
    expect(meta, isNotNull);
    expect(meta!.sourceType, ImageSourceType.comfyui); // 参数仍走 ComfyUI 解析
    // LoRA 换成 A1111 块那份:真名 + 哈希
    expect(meta.loras.map((l) => l.name), ['某某画风 v2', '角色A']);
    expect(meta.loras[0].hash, 'a1b2c3d4e5f6');
    expect(
      meta.loras.any((l) => l.name.contains('LR23')),
      isFalse,
      reason: '内部编号不该出现在给用户看的 LoRA 名里',
    );
  });

  test('只有工作流块(第三方 ComfyUI 图):退回文件名,无哈希', () async {
    final graph = jsonEncode({
      '19': {
        'class_type': 'KSampler',
        'inputs': {
          'steps': 8,
          'cfg': 7.0,
          'sampler_name': 'euler',
          'scheduler': 'normal',
          'seed': 7,
          'positive': ['11', 0],
          'negative': ['12', 0],
          'model': ['200', 0],
          'latent_image': ['28', 0],
        },
      },
      '12': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'blurry'},
      },
      '11': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'cat'},
      },
      '28': {
        'class_type': 'EmptyLatentImage',
        'inputs': {'width': 512, 'height': 512},
      },
      '200': {
        'class_type': 'LoraLoader',
        'inputs': {
          'lora_name': 'someStyle.safetensors',
          'strength_model': 0.7,
          'model': ['44', 0],
        },
      },
      '44': {
        'class_type': 'UNETLoader',
        'inputs': {'unet_name': 'x.safetensors'},
      },
    });
    final meta = await extractImageMetadata(pngWithChunks({'prompt': graph}));
    expect(meta, isNotNull);
    expect(meta!.loras.length, 1);
    expect(meta.loras[0].name, 'someStyle');
    expect(meta.loras[0].hash, isNull); // 没哈希 → 只能靠名字认领
  });
}

/// PNG 块校验用的 CRC32。
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
