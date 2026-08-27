import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/gen_modules.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/lora_triggers.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/state_codec.dart';

ActiveLora _lr(
  String name, {
  double weight = 0.8,
  bool enabled = true,
  double? clipWeight,
  LoraPending? pending,
  List<String> triggers = const [],
}) => ActiveLora(
  name: name,
  displayName: '$name 名',
  weight: weight,
  enabled: enabled,
  clipWeight: clipWeight,
  pending: pending,
  triggerWords: triggers,
);

GenerateState _animaState(List<ActiveLora> loras) =>
    GenerateState.initial().copyWith(
      prompt: '1girl',
      loras: loras,
      params: const GenParams().copyWith(model: 'Anima Turbo'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('触发词 ↔ 正向词', () {
    test('append 逐 tag 去重,尾逗号清理', () {
      expect(
        appendTriggerToPrompt('1girl, solo,', 'grey hair, long hair'),
        '1girl, solo, grey hair, long hair',
      );
      // 已有的 tag 不重复加入(大小写/权重括号不敏感)
      expect(
        appendTriggerToPrompt('1girl, (Grey Hair:1.2)', 'grey hair, ahoge'),
        '1girl, (Grey Hair:1.2), ahoge',
      );
      expect(appendTriggerToPrompt('', 'plana'), 'plana');
    });

    test('has:条目内全部 tag 都在才算已加入;中文逗号等价', () {
      expect(promptHasTrigger('1girl, grey hair', 'grey hair, halo'), isFalse);
      expect(
        promptHasTrigger('1girl，grey hair，halo', 'grey hair, halo'),
        isTrue,
      );
      expect(promptHasTrigger('1girl', ''), isFalse);
    });

    test('remove:剥掉条目内 tag,带权重写法一并命中', () {
      expect(
        removeTriggerFromPrompt(
          '1girl, {grey hair}, halo, solo',
          'grey hair, halo',
        ),
        '1girl, solo',
      );
      // 不在词里的照旧
      expect(removeTriggerFromPrompt('1girl, solo', 'plana'), '1girl, solo');
    });

    test('removeLoraTriggers:整条在场才清,他人占用的 tag 留下', () {
      // grey hair 只属被删者 → 清;long hair 仍被另一 LoRA 的在场触发词占用 → 留
      expect(
        removeLoraTriggersFromPrompt(
          '1girl, grey hair, long hair, solo',
          ['grey hair, long hair'],
          keepTriggers: [
            ['long hair'],
          ],
        ),
        '1girl, long hair, solo',
      );
      // 条目不完整在场(用户手删过一半)→ 整条不碰
      expect(
        removeLoraTriggersFromPrompt('1girl, grey hair', ['grey hair, halo']),
        '1girl, grey hair',
      );
      // 占用方触发词自身不在场 → 不构成保护
      expect(
        removeLoraTriggersFromPrompt(
          '1girl, halo',
          ['halo'],
          keepTriggers: [
            ['halo, wings'],
          ],
        ),
        '1girl',
      );
    });

    test('removeLora:删卡连带收触发词,在架他卡占用的留下', () {
      final stores = AppStores.ephemeral();
      final c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(() async {
        c.dispose();
        stores.flushNow();
      });
      final n = c.read(generateProvider.notifier);
      n.applyLoraSelection([
        _lr('a', triggers: ['grey hair, long hair']),
        _lr('b', triggers: ['long hair']),
      ]);
      n.setPrompts(positive: '1girl, grey hair, long hair, solo');
      n.removeLora('a');
      expect(c.read(generateProvider).prompt, '1girl, long hair, solo');
      expect(c.read(generateProvider).loras.map((l) => l.name), ['b']);
    });
  });

  group('载荷与剥离', () {
    test('anima_extra.loras:仅启用的、triggers 恒空、超限截断', () {
      // 上限 + 2 条启用的 + 1 条停用的:够触发截断,也够验证「停用不占名额」
      final s = _animaState([
        _lr('LR1', weight: 0.6),
        _lr('LR2', enabled: false),
        for (var i = 3; i <= kMaxActiveLoras + 3; i++) _lr('LR$i'),
      ]);
      final params = buildBotParams(s, seed: 1, presetId: 'none');
      final loras =
          (params['anima_extra'] as Map<String, dynamic>)['loras'] as List;
      // LR2 停用被跳过;启用的截到上限
      expect(loras, hasLength(kMaxActiveLoras));
      expect(
        [for (final l in loras) (l as Map)['name']],
        ['LR1', for (var i = 3; i < kMaxActiveLoras + 2; i++) 'LR$i'],
      );
      expect((loras.first as Map)['weight'], 0.6);
      expect((loras.first as Map)['triggers'], isEmpty);
    });

    test('clip_weight:设过才发,没设过让服务端跟随 weight', () {
      final s = _animaState([
        _lr('LR1', weight: 0.8, clipWeight: 0.4),
        _lr('LR2', weight: 0.6),
      ]);
      final loras =
          (buildBotParams(s, seed: 1, presetId: 'none')['anima_extra']
                  as Map<String, dynamic>)['loras']
              as List;
      expect((loras.first as Map)['clip_weight'], 0.4);
      expect((loras.last as Map).containsKey('clip_weight'), isFalse);
    });

    test('下载中的占位条绝不进载荷(机房还没有这文件)', () {
      final s = _animaState([
        _lr('LR1', weight: 0.8),
        _lr(pendingLoraKey(999), pending: const LoraPending(versionId: 999)),
      ]);
      final loras =
          (buildBotParams(s, seed: 1, presetId: 'none')['anima_extra']
                  as Map<String, dynamic>)['loras']
              as List;
      expect([for (final l in loras) (l as Map)['name']], ['LR1']);
    });

    test('只剩占位条时整个 loras 键都不带', () {
      final s = _animaState([
        _lr(pendingLoraKey(999), pending: const LoraPending(versionId: 999)),
      ]);
      expect(
        (buildBotParams(s, seed: 1, presetId: 'none')['anima_extra']
                as Map<String, dynamic>)
            .containsKey('loras'),
        isFalse,
      );
    });

    test('全部停用时不带 loras 键', () {
      final s = _animaState([_lr('LR1', enabled: false)]);
      final params = buildBotParams(s, seed: 1, presetId: 'none');
      expect(
        (params['anima_extra'] as Map<String, dynamic>).containsKey('loras'),
        isFalse,
      );
    });

    test('lora 模块归 anima 组:NAI 下剥离,anima 下保留', () {
      const ms = GenModuleSettings();
      expect(ms.visibleFor('Anima Turbo'), [
        GenModule.animaNl,
        GenModule.lora,
        GenModule.hires,
      ]);
      expect(ms.isVisibleFor(GenModule.lora, 'NAI 4.5 Full'), isFalse);

      final naiState = _animaState([
        _lr('LR1'),
      ]).copyWith(params: const GenParams().copyWith(model: 'NAI 4.5 Full'));
      expect(stripHiddenModules(naiState, ms).loras, isEmpty);
      expect(
        stripHiddenModules(_animaState([_lr('LR1')]), ms).loras,
        hasLength(1),
      );
    });
  });

  test('工作台序列化往返保留 LoRA', () async {
    final blobs = AppStores.ephemeral().blobs;
    final s = _animaState([
      _lr('LR1', weight: 1.25, enabled: false, triggers: ['plana, halo']),
    ]);
    final enc = await encodeGenerateState(s, blobs);
    final back = await decodeGenerateState(enc.json, blobs);
    final l = back.loras.single;
    expect(l.name, 'LR1');
    expect(l.displayName, 'LR1 名');
    expect(l.weight, 1.25);
    expect(l.enabled, isFalse);
    expect(l.triggerWords, ['plana, halo']);
  });

  group('工作台序列化往返保留重绘放大', () {
    test('整块常驻:关着的配置也原样回来', () async {
      final blobs = AppStores.ephemeral().blobs;
      final s = _animaState(const []).copyWith(
        params: const GenParams().copyWith(
          model: 'Anima Turbo',
          hires: const HiresConfig(
            scale: 1.85,
            denoise: 0.35,
            steps: 24,
            useModel: false,
            model: HiresUpscaler.anime6b,
          ),
        ),
      );
      final enc = await encodeGenerateState(s, blobs);
      final h = (await decodeGenerateState(enc.json, blobs)).params.hires;
      expect(h.enabled, isFalse);
      expect(h.scale, 1.85);
      expect(h.denoise, 0.35);
      expect(h.steps, 24);
      expect(h.useModel, isFalse);
      expect(h.model, HiresUpscaler.anime6b);
    });

    test('老存档无 hires 键 → 取默认(关闭、先超分后重绘)', () async {
      final blobs = AppStores.ephemeral().blobs;
      final enc = await encodeGenerateState(_animaState(const []), blobs);
      (enc.json['params'] as Map).remove('hires');
      final h = (await decodeGenerateState(enc.json, blobs)).params.hires;
      expect(h.enabled, isFalse);
      expect(h.useModel, isTrue);
      expect(h.model, HiresUpscaler.animesharp);
      expect(h.scale, 1.5);
    });
  });

  test('updateHires:二段步数 1~3 就地钳到服务端下限,0 原样(跟随主步数)', () {
    final stores = AppStores.ephemeral();
    final c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(() async {
      c.dispose();
      stores.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    final n = c.read(generateProvider.notifier);
    n.updateHires(steps: 2);
    expect(c.read(generateProvider).params.hires.steps, kHiresStepsMin);
    n.updateHires(steps: 99);
    expect(c.read(generateProvider).params.hires.steps, kHiresStepsMax);
    n.updateHires(steps: 0);
    expect(c.read(generateProvider).params.hires.steps, 0);
    // 开启时自动展开面板(与挂 LoRA / 选底图同一手感)
    n.updateHires(enabled: true);
    expect(c.read(generateProvider).openPanels, contains(Panel.hires));
  });

  test('applyLoraSelection:保留已挂条目的手调参数,新条目用推荐值', () {
    final stores = AppStores.ephemeral();
    final c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(() async {
      c.dispose();
      stores.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    final n = c.read(generateProvider.notifier);
    n.applyLoraSelection([_lr('LR1'), _lr('LR2')]);
    n.updateLora('LR1', weight: 1.5, enabled: false);

    // 重新确认选择:LR1 仍保留手调 weight/enabled,LR3 为新条目
    final kept = n.applyLoraSelection([
      _lr('LR1', weight: 0.8),
      _lr('LR3', weight: 0.7),
    ]);
    expect(kept, 2);
    final loras = c.read(generateProvider).loras;
    expect([for (final l in loras) l.name], ['LR1', 'LR3']);
    expect(loras.first.weight, 1.5);
    expect(loras.first.enabled, isFalse);
    expect(loras.last.weight, 0.7);

    // 超限:只收前 kMaxActiveLoras 个
    final n2 = c.read(generateProvider.notifier);
    final got = n2.applyLoraSelection([
      for (var i = 0; i < kMaxActiveLoras + 3; i++) _lr('LR$i'),
    ]);
    expect(got, kMaxActiveLoras);
    expect(c.read(generateProvider).loras, hasLength(kMaxActiveLoras));
  });

  group('占位条(导入了但机房还没有)', () {
    ProviderContainer container() {
      final stores = AppStores.ephemeral();
      final c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(() async {
        c.dispose();
        stores.flushNow();
      });
      return c;
    }

    test('转正:原地替换、位置不动,保留下载期间改过的权重/启停', () {
      final c = container();
      final n = c.read(generateProvider.notifier);
      const vid = 4242;
      n.applyLoraSelection([
        _lr('LR1'),
        _lr(pendingLoraKey(vid), pending: const LoraPending(versionId: vid)),
        _lr('LR9'),
      ]);
      n.updateLora(pendingLoraKey(vid), weight: 1.1, enabled: false);

      expect(
        n.promotePendingLora(
          pendingLoraKey(vid),
          _lr('LR7', weight: 0.8),
        ),
        isTrue,
      );
      final after = c.read(generateProvider).loras;
      expect([for (final l in after) l.name], ['LR1', 'LR7', 'LR9']);
      expect(after[1].pending, isNull); // 转正后不再是占位条
      expect(after[1].weight, 1.1); // 下载期间用户改过的留着
      expect(after[1].enabled, isFalse);
    });

    test('转正时发现同一个 LoRA 已从别处挂上 → 撤掉占位条,不留两条', () {
      final c = container();
      final n = c.read(generateProvider.notifier);
      const vid = 55;
      n.applyLoraSelection([
        _lr('LR7'),
        _lr(pendingLoraKey(vid), pending: const LoraPending(versionId: vid)),
      ]);
      n.promotePendingLora(pendingLoraKey(vid), _lr('LR7'));
      expect([
        for (final l in c.read(generateProvider).loras) l.name,
      ], ['LR7']);
    });

    test('占位条已被移除:装好也不追加回去(点了移除就该是移除)', () {
      final c = container();
      final n = c.read(generateProvider.notifier);
      const vid = 99;
      n.applyLoraSelection([
        _lr('LR1'),
        _lr(pendingLoraKey(vid), pending: const LoraPending(versionId: vid)),
      ]);
      // 用户在下载期间把占位条移掉了
      n.applyLoraSelection([_lr('LR1')]);

      expect(n.promotePendingLora(pendingLoraKey(vid), _lr('LR7')), isFalse);
      expect([
        for (final l in c.read(generateProvider).loras) l.name,
      ], ['LR1']);
    });

    test('下载失败:标红停用留在原地,不默默消失', () {
      final c = container();
      final n = c.read(generateProvider.notifier);
      const vid = 77;
      n.applyLoraSelection([
        _lr(pendingLoraKey(vid), pending: const LoraPending(versionId: vid)),
      ]);
      n.markLoraFailed(pendingLoraKey(vid), '机房超时');
      final l = c.read(generateProvider).loras.single;
      expect(l.pending?.failed, '机房超时');
      expect(l.enabled, isFalse);
    });

    test('占位条不进存档(安装队列在内存里,重启就没了)', () async {
      const vid = 8;
      final blobs = AppStores.ephemeral().blobs;
      final s = _animaState([
        _lr('LR1'),
        _lr(pendingLoraKey(vid), pending: const LoraPending(versionId: vid)),
      ]);
      final enc = await encodeGenerateState(s, blobs);
      expect(
        (enc.json['loras'] as List).map((e) => (e as Map)['name']),
        ['LR1'],
      );
      final back = await decodeGenerateState(enc.json, blobs);
      expect(back.loras.single.name, 'LR1');
    });
  });
}
