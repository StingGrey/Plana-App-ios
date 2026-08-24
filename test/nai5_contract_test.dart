// V5 上线后与 web 对齐的三条硬契约(2026-08-24 同步)。
//
// 三条都是**静默错**:发错了不崩、不报错,只是元数据写进去是错的、或者字段被
// 服务端悄悄丢掉。人工点一遍 UI 一个都看不出来 —— 只能靠测试钉住。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'package:plana_app/features/import/image_metadata.dart';

/// 一份**故意把两个 V5 不支持的开关都打开**的状态:非 karras + Variety+。
/// 用户切到 V5 之前留下的值就长这样,收口没做好它们就会被带出去。
GenerateState _state(String model) => GenerateState.initial().copyWith(
  prompt: '1girl',
  params: const GenParams().copyWith(
    model: model,
    seed: '1',
    noiseSchedule: 'exponential',
    varietyPlus: true,
  ),
);

Map<String, dynamic> _direct(String model, {String presetId = 'heavy'}) =>
    buildNaiPayload(_state(model), presetId: presetId).body['parameters']
        as Map<String, dynamic>;

Map<String, dynamic> _bot(String model, {String presetId = 'heavy'}) =>
    buildBotParams(_state(model), seed: 1, presetId: presetId);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ucPreset 的数值是**档位数组的下标**,直连与 bot 两条线共用同一张官方表。
  // 曾经按线拆成两张(bot 线是一套自造的反向取值 heavy→4 / none→0),web 把
  // bot 线也换成官方表时 app 只跟了一半 —— 于是「重度」被写进图片元数据时
  // 成了「无」。拆表就是这个 bug 的成因,所以这一组同时钉住「值对」和「两条线一致」。
  group('ucPresetValue:两条线共用官方下标表', () {
    test('官方档位数组 [heavy, light, furryFocus, humanFocus, none] 的下标', () {
      expect(ucPresetValue('heavy'), 0);
      expect(ucPresetValue('light'), 1);
      expect(ucPresetValue('furryFocus'), 2);
      expect(ucPresetValue('humanFocus'), 3);
      expect(ucPresetValue('none'), 4);
    });

    test('v5 档跟随它所用的官方负面档', () {
      expect(ucPresetValue('v5-standard'), ucPresetValue('heavy'));
      expect(ucPresetValue('v5-light'), ucPresetValue('light'));
    });

    test('自定义预设落 none —— 负面词是用户自己写的,不该宣称套了官方档', () {
      expect(kUcPresetNone, 4);
      expect(ucPresetValue('preset-1755999999'), kUcPresetNone);
      expect(ucPresetValue(''), kUcPresetNone);
    });

    test('同一档在直连与 bot 发出的是同一个数', () {
      for (final id in ['heavy', 'light', 'none', 'preset-1755999999']) {
        expect(
          _direct('NAI 4.5 Full', presetId: id)['ucPreset'],
          _bot('NAI 4.5 Full', presetId: id)['ucPreset'],
          reason: id,
        );
      }
    });
  });

  // 官方能力表里 V5 的 noiseSchedule / cfgDelay 都是 false:请求清洗会把
  // noise_schedule 硬写回 karras、把 skip_cfg_above_sigma 删掉。带过去不会报错,
  // 只是白发 —— 但用户切模型前留下的开关会一直显示成"开着",所以两条线都收口。
  group('V5 不发它没有的两项能力', () {
    test('直连:noise_schedule 恒 karras', () {
      expect(_direct('NAI 5.0 Full')['noise_schedule'], 'karras');
      expect(_direct('NAI 5.0 Curated')['noise_schedule'], 'karras');
    });

    test('直连:Variety+ 开着也不发 skip_cfg_above_sigma', () {
      expect(_direct('NAI 5.0 Full')['skip_cfg_above_sigma'], isNull);
    });

    test('bot:同一口径(后端还会再兜一道,但别指望它)', () {
      expect(_bot('NAI 5.0 Full')['noiseSchedule'], 'karras');
      expect(_bot('NAI 5.0 Full')['varietyPlus'], isFalse);
    });

    test('4.5 不受影响:用户选什么发什么', () {
      expect(_direct('NAI 4.5 Full')['noise_schedule'], 'exponential');
      expect(_direct('NAI 4.5 Full')['skip_cfg_above_sigma'], 58);
      expect(_bot('NAI 4.5 Full')['noiseSchedule'], 'exponential');
      expect(_bot('NAI 4.5 Full')['varietyPlus'], isTrue);
    });
  });

  // 透明背景:straight_alpha 跟官方一样「只要模型支持就无条件发」(它只是 alpha
  // 的编码约定),tag_hint 才是记录「这张到底透不透明」的那个,由提示词触发。
  group('透明背景字段', () {
    GenerateState withPrompt(String model, String prompt) =>
        GenerateState.initial().copyWith(
          prompt: prompt,
          params: const GenParams().copyWith(model: model, seed: '1'),
        );

    Map<String, dynamic> direct(GenerateState s, {bool straight = true}) =>
        buildNaiPayload(
              s,
              presetId: 'none',
              straightAlpha: straight,
            ).body['parameters']
            as Map<String, dynamic>;

    test('V5:straight_alpha 恒发,tag_hint 跟提示词走', () {
      final on = direct(
        withPrompt('NAI 5.0 Full', '1girl, transparent background'),
      );
      expect(on['straight_alpha'], isTrue);
      expect(on['tag_hint_transparent_background'], isTrue);

      final off = direct(withPrompt('NAI 5.0 Full', '1girl'));
      expect(off['straight_alpha'], isTrue);
      expect(off['tag_hint_transparent_background'], isFalse);
    });

    test('设置里改成预乘 → straight_alpha false', () {
      final p = direct(withPrompt('NAI 5.0 Full', '1girl'), straight: false);
      expect(p['straight_alpha'], isFalse);
    });

    test('非 V5 一个字段都不发', () {
      final p = direct(
        withPrompt('NAI 4.5 Full', '1girl, transparent background'),
      );
      expect(p.containsKey('straight_alpha'), isFalse);
      expect(p.containsKey('tag_hint_transparent_background'), isFalse);
    });

    // 看的是**最终要发的** model:V5 Curated 的重绘会回退到 4.5 Curated
    // Inpainting,那个模型没有 transparency 能力,不该跟着发。
    test('V5 Curated 重绘回退到 4.5 → 不发', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final s = withPrompt('NAI 5.0 Curated', 'transparent background')
          .copyWith(
            inpaint: InpaintJob(image: bytes, mask: bytes, strength: 0.7),
          );
      final p = direct(s);
      expect(p.containsKey('straight_alpha'), isFalse);
      // V5 Full 的重绘模型已上线,那条照发
      final full = withPrompt('NAI 5.0 Full', 'transparent background')
          .copyWith(
            inpaint: InpaintJob(image: bytes, mask: bytes, strength: 0.7),
          );
      expect(direct(full)['straight_alpha'], isTrue);
    });

    test('bot 线同口径(camelCase)', () {
      final p = buildBotParams(
        withPrompt('NAI 5.0 Full', '1girl, transparent background'),
        seed: 1,
        presetId: 'none',
      );
      expect(p['straightAlpha'], isTrue);
      expect(p['tagHintTransparentBackground'], isTrue);
      final legacy = buildBotParams(
        withPrompt('NAI 4.5 Full', 'transparent background'),
        seed: 1,
        presetId: 'none',
      );
      expect(legacy.containsKey('straightAlpha'), isFalse);
    });
  });

  // V5 的 Source 串里**不写 Full / Curated**,只有权重 hash。按字面找 curated
  // 永远不成立 —— 那样写会把每一张 V5 图都认成 Full(本仓 2026-08-24 前就是)。
  group('naiSourceIsV5Full:V5 认 hash 不认字面', () {
    test('白名单里的两个 hash 是 Full', () {
      expect(naiSourceIsV5Full('NovelAI Diffusion V5 657484A5'), isTrue);
      expect(naiSourceIsV5Full('NovelAI Diffusion V5 0ADF9AB7'), isTrue);
    });

    test('其余 V5 一律 Curated(官方那边就是 default 分支)', () {
      expect(naiSourceIsV5Full('NovelAI Diffusion V5 12345678'), isFalse);
      expect(naiSourceIsV5Full('NovelAI Diffusion V5'), isFalse);
    });

    test('大小写不敏感', () {
      expect(naiSourceIsV5Full('novelai diffusion v5 657484a5'), isTrue);
    });

    test('归一化之后的串也吃得下(那时 hash 已经没了,只能看字面)', () {
      expect(naiSourceIsV5Full('NovelAI V5 Full'), isTrue);
      expect(naiSourceIsV5Full('NovelAI V5 Curated'), isFalse);
    });
  });
}
