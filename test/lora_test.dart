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
  List<String> triggers = const [],
}) => ActiveLora(
  name: name,
  displayName: '$name 名',
  weight: weight,
  enabled: enabled,
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
      final s = _animaState([
        _lr('LR1', weight: 0.6),
        _lr('LR2', enabled: false),
        _lr('LR3'),
        _lr('LR4'),
        _lr('LR5'),
        _lr('LR6'),
        _lr('LR7'),
      ]);
      final params = buildBotParams(s, seed: 1, presetId: 'none');
      final loras =
          (params['anima_extra'] as Map<String, dynamic>)['loras'] as List;
      // LR2 停用被跳过;启用的 6 个截到上限 5
      expect(loras, hasLength(kMaxActiveLoras));
      expect(
        [for (final l in loras) (l as Map)['name']],
        ['LR1', 'LR3', 'LR4', 'LR5', 'LR6'],
      );
      expect((loras.first as Map)['weight'], 0.6);
      expect((loras.first as Map)['triggers'], isEmpty);
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
      expect(ms.visibleFor('Anima Turbo'), [GenModule.lora]);
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

    // 超限:只收前 5 个
    final n2 = c.read(generateProvider.notifier);
    final got = n2.applyLoraSelection([
      for (var i = 0; i < 8; i++) _lr('LR$i'),
    ]);
    expect(got, kMaxActiveLoras);
    expect(c.read(generateProvider).loras, hasLength(kMaxActiveLoras));
  });
}
