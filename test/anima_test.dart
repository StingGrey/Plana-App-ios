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
    // anima 组只有自然语言描述 + LoRA + 重绘放大(NAI 四件套全部收走)
    expect(ms.visibleFor('Anima Turbo'), [
      GenModule.animaNl,
      GenModule.lora,
      GenModule.hires,
    ]);
    final out = stripHiddenModules(_animaState(), ms);
    expect(out.characters, isEmpty);
    expect(out.vibes, isEmpty);
    expect(out.charRefs, isEmpty);
    expect(out.img2img, isNull);
  });

  test('anima 下角色不计入 token 读数(计数幽灵)', () {
    const ms = GenModuleSettings();
    // anima:角色模块整组收走 → 一个不计,读数不会凭空变大
    expect(countedCharacters(_animaState(), ms), isEmpty);
    // NAI:启用的照计,手动关掉的不计
    final nai = GenerateState.initial().copyWith(
      characters: const [
        CharacterPrompt(id: 'c1', name: 'a', positive: '1girl'),
        CharacterPrompt(id: 'c2', name: 'b', positive: '1boy', enabled: false),
      ],
    );
    expect(countedCharacters(nai, ms).map((c) => c.id), ['c1']);
    // 用户在模块管理里关掉角色卡 → 同样不计(与剥离层同一判定)
    expect(
      countedCharacters(
        nai,
        const GenModuleSettings(enabled: {GenModule.character: false}),
      ),
      isEmpty,
    );
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

  group('重绘放大 hires', () {
    Map<String, dynamic> extraOf(HiresConfig h) {
      final s = _animaState().copyWith(
        params: _animaState().params.copyWith(hires: h),
      );
      final params = buildBotParams(s, seed: 42, presetId: 'none');
      return params['anima_extra'] as Map<String, dynamic>;
    }

    test('关着不发 hires 键', () {
      expect(extraOf(const HiresConfig()).containsKey('hires'), isFalse);
    });

    test('先超分后重绘:upscaler 发超分模型键(服务端白名单名)', () {
      final h =
          extraOf(
                const HiresConfig(
                  enabled: true,
                  scale: 1.75,
                  denoise: 0.4,
                  steps: 20,
                  model: HiresUpscaler.ultrasharp,
                ),
              )['hires']
              as Map<String, dynamic>;
      expect(h, {
        'scale': 1.75,
        'denoise': 0.4,
        'steps': 20,
        'upscaler': 'ultrasharp',
      });
    });

    test('直接重绘发 lanczos,选过的超分模型不参与载荷', () {
      final h =
          extraOf(
                const HiresConfig(
                  enabled: true,
                  useModel: false,
                  model: HiresUpscaler.anime6b,
                ),
              )['hires']
              as Map<String, dynamic>;
      expect(h['upscaler'], 'lanczos');
    });

    test('steps=0 不发键(服务端据此跟随主步数)', () {
      final h =
          extraOf(const HiresConfig(enabled: true))['hires']
              as Map<String, dynamic>;
      expect(h.containsKey('steps'), isFalse);
    });

    test('目标尺寸算法对齐服务端 int(base*scale)//8*8', () {
      expect(const HiresConfig().targetSize(832, 1216), (1248, 1824));
      expect(const HiresConfig(scale: 2.0).targetSize(832, 1216), (1664, 2432));
      // 非整除时向下对齐到 8 的倍数
      expect(const HiresConfig(scale: 1.15).targetSize(832, 1216), (952, 1392));
    });

    test('模块隐藏时开关被剥离(配置本身留着)', () {
      final s = _animaState().copyWith(
        params: _animaState().params.copyWith(
          hires: const HiresConfig(enabled: true, scale: 1.8),
        ),
      );
      final out = stripHiddenModules(
        s,
        const GenModuleSettings(enabled: {GenModule.hires: false}),
      );
      expect(out.params.hires.enabled, isFalse);
      expect(out.params.hires.scale, 1.8);
      expect(
        buildBotParams(
          out,
          seed: 1,
          presetId: 'none',
        )['anima_extra'].containsKey('hires'),
        isFalse,
      );
    });

    test('NAI 模型下开着也不发(整个 anima_extra 都不发)', () {
      final s = GenerateState.initial().copyWith(
        params: const GenParams().copyWith(
          hires: const HiresConfig(enabled: true),
        ),
      );
      final params = buildBotParams(s, seed: 1, presetId: 'none');
      expect(params.containsKey('anima_extra'), isFalse);
    });
  });
}
