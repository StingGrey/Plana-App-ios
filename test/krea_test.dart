import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/cost.dart';
import 'package:plana_app/features/generate/gen_modules.dart';
import 'package:plana_app/features/generate/models.dart';

Uint8List _px(int seed) => Uint8List.fromList([seed, seed, seed]);

/// 带满 NAI 数据的 krea 状态:剥离测试要能看出「哪些被收走了」。
GenerateState _kreaState() => GenerateState.initial().copyWith(
  prompt: '一个女孩站在雨后的天台上',
  characters: const [CharacterPrompt(id: 'c1', name: 'x', positive: '1girl')],
  vibes: const [VibeItem(id: 'v1')],
  charRefs: const [CharRefItem(id: 'r1')],
  img2img: const Img2ImgConfig(),
  loras: const [ActiveLora(name: 'LR7', displayName: '画风', weight: 0.6)],
  kreaStyleRefs: [KreaStyleRefItem(id: 'k1', image: _px(1))],
  // 档位默认由 setModel 应用;此处显式给值,载荷测试只验映射
  params: const GenParams().copyWith(
    model: 'Krea 2 Raw',
    kreaSteps: 36,
    kreaCfg: 3.5,
  ),
);

void main() {
  test('provider 归组与档位映射', () {
    expect(providerOfModel('Krea 2 Turbo'), GenProvider.krea);
    expect(providerOfModel('Krea 2 Raw'), GenProvider.krea);
    expect(providerOfModel('Anima Turbo'), GenProvider.anima);
    expect(providerOfModel('NAI 4.5 Full'), GenProvider.nai);
    expect(kreaTierOf('Krea 2 Turbo'), 'turbo');
    expect(kreaTierOf('Krea 2 Raw'), 'raw');
    // 未识别一律回落 raw(与服务端 normalize_krea_tier 同一默认)
    expect(kreaTierOf('Krea 2 什么档'), 'raw');
    // Modal 通道 = anima + krea,NAI 不在其中
    expect(isModalModel('Krea 2 Raw'), isTrue);
    expect(isModalModel('Anima Base'), isTrue);
    expect(isModalModel('NAI 4.5 Full'), isFalse);
  });

  // raw 2026-08-09 随 web 由 28 提到 36(官方 52 步太贵,取的折中值)。
  test('档位默认值对齐 web KREA_TIER_DEFAULTS', () {
    // 两档采样器相同(官方配方),切档仍会重置 —— 与 steps/cfg 行为一致
    expect(kreaTierDefaults('turbo'), (
      steps: 8,
      cfg: 1.0,
      sampler: 'er_sde',
      scheduler: 'simple',
    ));
    expect(kreaTierDefaults('raw'), (
      steps: 36,
      cfg: 3.5,
      sampler: 'er_sde',
      scheduler: 'simple',
    ));
    // CFG=1 的蒸馏档负向词不参与引导 —— UI 据此提示
    expect(kreaNegativeWorks('turbo'), isFalse);
    expect(kreaNegativeWorks('raw'), isTrue);
  });

  // 表与服务端 _KREA_SAMPLER_WHITELIST / _KREA_SCHEDULER_WHITELIST 同步;
  // 表外的值服务端静默回退档位默认,所以 UI 只给表内选项。
  test('采样器/调度器白名单对齐 web kreaOptions', () {
    expect(kreaSamplers.map((o) => o.id), [
      'er_sde',
      'euler',
      'euler_ancestral',
      'dpmpp_2m_sde_gpu',
      'dpmpp_2m',
      'dpmpp_sde_gpu',
      'uni_pc',
      'uni_pc_bh2',
    ]);
    expect(kreaSchedulers.map((o) => o.id), [
      'simple',
      'normal',
      'sgm_uniform',
      'beta',
      'karras',
    ]);
    // karras 两档实测都崩,但仍留在表里(参数全面放开),靠 UI 当场提示
    expect(kreaSchedulerRisky('karras'), isTrue);
    expect(kreaSchedulerRisky('simple'), isFalse);
  });

  test('三套步数互不干扰,范围各自独立', () {
    const p = GenParams();
    expect(p.copyWith(model: 'NAI 4.5 Full').activeSteps, p.steps);
    expect(p.copyWith(model: 'Anima Base').activeSteps, p.animaSteps);
    expect(p.copyWith(model: 'Krea 2 Raw').activeSteps, p.kreaSteps);
    // 写回只动当前父类那一份
    final k = p.copyWith(model: 'Krea 2 Raw').withActiveSteps(44);
    expect(k.kreaSteps, 44);
    expect(k.steps, p.steps);
    expect(k.animaSteps, p.animaSteps);
    // Krea 上限比另外两套高(服务端硬夹 60)
    expect(stepsRangeOf('Krea 2 Raw'), kreaStepsRange);
    expect(stepsRangeOf('Anima Base'), animaStepsRange);
    expect(stepsRangeOf('NAI 4.5 Full'), (min: 1, max: 50));
  });

  test('krea 下只剩自己那三个模块,NAI 数据整组剥离', () {
    const ms = GenModuleSettings();
    expect(ms.visibleFor('Krea 2 Raw'), [
      GenModule.kreaLora,
      GenModule.kreaPrompt,
      GenModule.kreaStyleRef,
    ]);
    final out = stripHiddenModules(_kreaState(), ms);
    expect(out.characters, isEmpty);
    expect(out.vibes, isEmpty);
    expect(out.charRefs, isEmpty);
    expect(out.img2img, isNull);
    // krea 自己的两块留着
    expect(out.loras, hasLength(1));
    expect(out.kreaStyleRefs, hasLength(1));
  });

  test('LoRA 启用位两个父类各存各的', () {
    // 在 Anima 里关掉 LoRA,不影响 Krea(共用挂载列表,但 key 分开)
    const offAnima = GenModuleSettings(enabled: {GenModule.lora: false});
    expect(stripHiddenModules(_kreaState(), offAnima).loras, hasLength(1));
    // 关掉 krea 那个才收走
    const offKrea = GenModuleSettings(enabled: {GenModule.kreaLora: false});
    expect(stripHiddenModules(_kreaState(), offKrea).loras, isEmpty);
  });

  test('风格参考模块隐藏时整组剥离', () {
    const off = GenModuleSettings(enabled: {GenModule.kreaStyleRef: false});
    expect(stripHiddenModules(_kreaState(), off).kreaStyleRefs, isEmpty);
  });

  test('只有启用且有图的参考图会下发,并截到节点槽位上限', () {
    final s = _kreaState().copyWith(
      kreaStyleRefs: [
        KreaStyleRefItem(id: 'a', image: _px(1)),
        const KreaStyleRefItem(id: 'b', image: null), // 无图:发不出去
        KreaStyleRefItem(id: 'c', image: _px(3), enabled: false),
        KreaStyleRefItem(id: 'd', image: _px(4)),
        KreaStyleRefItem(id: 'e', image: _px(5)),
        KreaStyleRefItem(id: 'f', image: _px(6)), // 第 4 张启用的,超出上限
      ],
    );
    expect(s.activeKreaStyleRefs.map((r) => r.id), ['a', 'd', 'e']);
    expect(kMaxKreaStyleRefs, 3);
  });

  test('krea 不扣 Anlas', () {
    expect(estimateCost(_kreaState(), isOpus: false), 0);
    expect(estimateCost(_kreaState(), isOpus: true), 0);
  });

  test('buildBotParams:krea_extra 形状对齐服务端契约', () {
    final s = stripHiddenModules(_kreaState(), const GenModuleSettings());
    final params = buildBotParams(
      s,
      seed: 42,
      presetId: 'none',
      kreaStyleRefs: const ['AAAA', 'BBBB'],
    );
    final extra = params['krea_extra'] as Map<String, dynamic>;
    expect(extra['steps'], 36);
    expect(extra['cfg'], 3.5);
    expect(extra['model'], 'raw');
    // 2026-08-10 起采样器随载荷下发(此前是模板常量,UI 连字段都不存)
    expect(extra['sampler'], 'er_sde');
    expect(extra['scheduler'], 'simple');
    // 也没有 anima 那套 hires
    expect(extra.containsKey('hires'), isFalse);
    expect(extra['loras'], [
      {'name': 'LR7', 'weight': 0.6, 'triggers': <String>[]},
    ]);
    expect(extra['style_ref'], {
      'imagesBase64': ['AAAA', 'BBBB'],
      'weight': 1.0,
    });
    // 两条 extra 互斥,不混传
    expect(params.containsKey('anima_extra'), isFalse);
    // NAI 专属数据已剥离
    expect(params['characterPrompts'], isEmpty);
    expect(params.containsKey('vibeReferences'), isFalse);
    expect(params.containsKey('preciseReferences'), isFalse);
    expect(params.containsKey('img2img'), isFalse);
  });

  test('没有参考图就不发 style_ref 键', () {
    final extra =
        buildBotParams(_kreaState(), seed: 1, presetId: 'none')['krea_extra']
            as Map<String, dynamic>;
    expect(extra.containsKey('style_ref'), isFalse);
  });

  test('参考强度跟着状态走(全局一份)', () {
    final s = _kreaState().copyWith(kreaStyleRefWeight: 0.65);
    final extra =
        buildBotParams(
              s,
              seed: 1,
              presetId: 'none',
              kreaStyleRefs: const ['AAAA'],
            )['krea_extra']
            as Map<String, dynamic>;
    expect((extra['style_ref'] as Map)['weight'], 0.65);
  });

  test('非 krea 模型不带 krea_extra,也不会把参考图捎出去', () {
    final s = _kreaState().copyWith(
      params: _kreaState().params.copyWith(model: 'Anima Base'),
    );
    final params = buildBotParams(
      s,
      seed: 1,
      presetId: 'none',
      kreaStyleRefs: const ['AAAA'],
    );
    expect(params.containsKey('krea_extra'), isFalse);
    expect(params.containsKey('anima_extra'), isTrue);
  });

  test('LoRA 库按底模隔离', () {
    expect(loraBaseOf('Krea 2 Turbo'), 'krea');
    expect(loraBaseOf('Anima Base'), 'anima');
    // NAI 没有 LoRA 模块,归在 anima 那侧兜底 —— 于是 NAI↔Anima 来回切时
    // 挂载列表不会被 setModel 清空
    expect(loraBaseOf('NAI 4.5 Full'), 'anima');
  });
}
