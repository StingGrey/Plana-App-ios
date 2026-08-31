// 导入图片时的**角色负向**。
//
// 这是条静默错:角色正向、坐标都回来了,只有负向是空的 —— 界面上看不出少了东西,
// 用户重新出图才发现构图不对。根因是 `v4_prompt.caption.char_captions` 那份结构
// 里**压根没有角色负向**,读它的 `char_uc` 永远是空串(本仓 2026-08-31 前就是)。
//
// 负向的两个真出处:
//   1. `characterPrompts[].uc` —— 官方与本 app 都发,顺序与正向一一对应;
//   2. `v4_negative_prompt.caption.char_captions` —— **只收负向非空的那几个**,
//      下标跟正向对不上,只能按坐标认人。
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/features/import/image_metadata.dart';

Map<String, dynamic> _nai(Map<String, dynamic> comment) => {
  'Source': 'NovelAI Diffusion V4.5 abc',
  'Comment': comment,
};

Map<String, dynamic> _cap(String text, double x, double y) => {
  'char_caption': text,
  'centers': [
    {'x': x, 'y': y},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('characterPrompts[].uc:按下标对上正向', () {
    final m = parseNaiMetadataJson(
      _nai({
        'v4_prompt': {
          'caption': {
            'base_caption': '1girl',
            'char_captions': [_cap('plana', 0.3, 0.5), _cap('arona', 0.7, 0.5)],
          },
        },
        'characterPrompts': [
          {'prompt': 'plana', 'uc': 'bad hands', 'enabled': true},
          {'prompt': 'arona', 'uc': 'blurry', 'enabled': true},
        ],
      }),
    )!;

    expect([for (final c in m.characters) c.prompt], ['plana', 'arona']);
    expect([for (final c in m.characters) c.uc], ['bad hands', 'blurry']);
  });

  // 只有第二个角色写了负向时,负向那份只有一条 —— 按下标取会把它安到第一个头上。
  test('没有 characterPrompts 时按坐标认人,不按下标', () {
    final m = parseNaiMetadataJson(
      _nai({
        'v4_prompt': {
          'caption': {
            'char_captions': [
              _cap('plana', 0.3, 0.5),
              _cap('arona', 0.7, 0.5),
              _cap('yuuka', 0.5, 0.3),
            ],
          },
        },
        'v4_negative_prompt': {
          'caption': {
            'base_caption': 'lowres',
            'char_captions': [_cap('blurry', 0.7, 0.5)],
          },
        },
      }),
    )!;

    expect(m.negativePrompt, 'lowres');
    expect([for (final c in m.characters) c.uc], ['', 'blurry', '']);
  });

  test('两处都没有:负向留空,正向与坐标照常', () {
    final m = parseNaiMetadataJson(
      _nai({
        'v4_prompt': {
          'caption': {
            'char_captions': [_cap('plana', 0.3, 0.5)],
          },
        },
      }),
    )!;

    expect(m.characters.single.prompt, 'plana');
    expect(m.characters.single.uc, '');
    expect(m.characters.single.centerX, 0.3);
    expect(m.characters.single.centerY, 0.5);
  });

  // characterPrompts 缺项 / 长度对不上时不能越界,也不该把负向串到别人身上。
  test('characterPrompts 比正向短:短的那截回落坐标匹配', () {
    final m = parseNaiMetadataJson(
      _nai({
        'v4_prompt': {
          'caption': {
            'char_captions': [_cap('plana', 0.3, 0.5), _cap('arona', 0.7, 0.5)],
          },
        },
        'characterPrompts': [
          {'prompt': 'plana', 'uc': 'bad hands'},
        ],
        'v4_negative_prompt': {
          'caption': {
            'char_captions': [_cap('blurry', 0.7, 0.5)],
          },
        },
      }),
    )!;

    expect([for (final c in m.characters) c.uc], ['bad hands', 'blurry']);
  });
}
