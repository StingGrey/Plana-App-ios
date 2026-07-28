import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/cost.dart';
import 'package:plana_app/features/generate/gen_modules.dart';
import 'package:plana_app/features/generate/models.dart';

GenerateState _animaState() => GenerateState.initial().copyWith(
  prompt: '1girl, plana',
  characters: const [CharacterPrompt(id: 'c1', name: 'x', positive: '1girl')],
  vibes: const [VibeItem(id: 'v1')],
  charRefs: const [CharRefItem(id: 'r1')],
  img2img: const Img2ImgConfig(),
  // 档位默认由 setModel 应用;此处显式给值,载荷测试只验映射
  params: const GenParams().copyWith(
    model: 'Anima Aesthetic',
    animaSteps: 28,
    animaCfg: 4.5,
    animaSampler: 'er_sde',
  ),
);

void main() {
  test('provider 归组与档位映射', () {
    expect(providerOfModel('NAI 4.5 Full'), GenProvider.nai);
    expect(providerOfModel('Anima Turbo'), GenProvider.anima);
    expect(animaTierOf('Anima Turbo'), 'turbo');
    expect(animaTierOf('Anima Aesthetic'), 'aesthetic');
    expect(animaTierOf('Anima Base'), 'base');
  });

  test('档位默认值对齐 web ANIMA_TIER_DEFAULTS', () {
    final t = animaTierDefaults('turbo');
    expect(
      (t.steps, t.cfg, t.sampler, t.scheduler),
      (12, 1.0, 'euler', 'simple'),
    );
    final a = animaTierDefaults('aesthetic');
    expect(
      (a.steps, a.cfg, a.sampler, a.scheduler),
      (28, 4.5, 'er_sde', 'simple'),
    );
    expect(animaTierDefaults('base').steps, 28);
  });

  test('anima 下 NAI 模块全部不可见,数据整组剥离', () {
    const ms = GenModuleSettings();
    // anima 组只有 LoRA 模块(NAI 四件套全部收走)
    expect(ms.visibleFor('Anima Turbo'), [GenModule.lora]);
    final out = stripHiddenModules(_animaState(), ms);
    expect(out.characters, isEmpty);
    expect(out.vibes, isEmpty);
    expect(out.charRefs, isEmpty);
    expect(out.img2img, isNull);
  });

  test('anima 不扣 Anlas', () {
    expect(estimateCost(_animaState(), isOpus: false), 0);
    expect(estimateCost(_animaState(), isOpus: true), 0);
  });

  test('buildBotParams:anima_extra 形状对齐服务端契约', () {
    final s = stripHiddenModules(_animaState(), const GenModuleSettings());
    final params = buildBotParams(s, seed: 42, presetId: 'none');
    final extra = params['anima_extra'] as Map<String, dynamic>;
    expect(extra['steps'], 28);
    expect(extra['cfg'], 4.5);
    expect(extra['sampler'], 'er_sde');
    expect(extra['scheduler'], 'simple');
    expect(extra['model'], 'aesthetic');
    expect(extra['turbo'], isFalse);
    // NAI 专属数据已剥离:角色为空、无 vibe/CR/图生图块
    expect(params['characterPrompts'], isEmpty);
    expect(params.containsKey('vibeReferences'), isFalse);
    expect(params.containsKey('preciseReferences'), isFalse);
    expect(params.containsKey('img2img'), isFalse);
  });

  test('NAI 模型不带 anima_extra', () {
    final params = buildBotParams(
      GenerateState.initial(),
      seed: 1,
      presetId: 'none',
    );
    expect(params.containsKey('anima_extra'), isFalse);
  });
}
