// 换模型时角色槽位收口:V5 能摆 32 个,V4/V4.5 只有 6 个。
//
// 这是条**静默错**:两条发送线(nai_request / bot_request)都只按「启用且正向
// 非空」筛角色、**都不截断**,所以在 V5 下攒了 10 个角色再切回 4.5,第 7 个往后
// 照样会发出去,界面上却是一张写着「超限」的红标。收口放在切模型那一刻,把超出
// 的尾巴就地**停用**(不是删除)—— 切回 V5 时人还在,勾一下就回来。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';

/// 临时根目录 + 用完删(Windows 句柄释放有延迟,删不掉就留给系统清)。
Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('plana_char_cap');
  addTearDown(() async {
    for (var i = 0; i < 10; i++) {
      try {
        root.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  return root;
}

Future<GenerateNotifier> _notifier() async {
  final stores = await AppStores.open(rootOverride: _tempRoot());
  final c = ProviderContainer(
    overrides: [appStoresProvider.overrideWithValue(stores)],
  );
  addTearDown(c.dispose);
  return c.read(generateProvider.notifier);
}

/// V5 下攒 [n] 个角色(V5 槽位 32,attCharacter 不会被上限挡住)。
Future<GenerateNotifier> _withChars(int n) async {
  final gen = await _notifier();
  gen.setModel('NAI 5.0 Full');
  for (var i = 0; i < n; i++) {
    gen.addCharacter();
  }
  expect(gen.state.characters.length, n);
  return gen;
}

List<bool> _flags(GenerateNotifier gen) => [
  for (final c in gen.state.characters) c.enabled,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('5 → 4.5:超出槽位的尾巴自动停用,前 6 个照旧', () async {
    final gen = await _withChars(10);
    expect(_flags(gen), List.filled(10, true));

    gen.setModel('NAI 4.5 Full');
    expect(_flags(gen), [...List.filled(6, true), ...List.filled(4, false)]);
  });

  // 停用不是删除:切回去人还在,内容也没动过。
  test('一个都没删,名字内容原样', () async {
    final gen = await _withChars(10);
    final names = [for (final c in gen.state.characters) c.name];
    gen.setModel('NAI 4.0 Full');

    expect(gen.state.characters.length, 10);
    expect([for (final c in gen.state.characters) c.name], names);
  });

  // 已经手动停用的不占额度 —— 按位置砍会把这种本来就合规的配置砍到只剩 2 个。
  test('自己停过的不算数:10 张里停了 4 张,切下去一张都不动', () async {
    final gen = await _withChars(10);
    for (final c in gen.state.characters.take(4)) {
      gen.updateCharacter(c.id, enabled: false);
    }
    final before = _flags(gen);

    gen.setModel('NAI 4.5 Full');
    expect(_flags(gen), before);
    expect(gen.state.characters.where((c) => c.enabled).length, 6);
  });

  // 混着停用时也只砍尾巴,且砍到刚好够 6 个就停手。
  test('中间停过几张:从尾巴往前停,停到启用数正好落回 6', () async {
    final gen = await _withChars(10);
    gen.updateCharacter(gen.state.characters[1].id, enabled: false);
    gen.updateCharacter(gen.state.characters[3].id, enabled: false);

    gen.setModel('NAI 4.5 Full');
    // 启用的 8 个里保住前 6 个:0,2,4,5,6,7
    expect(_flags(gen), [
      true, false, true, false, // 1、3 是自己停的
      true, true, true, true, // 4..7 保住,凑满 6 个
      false, false, // 8、9 收口停用
    ]);
    expect(gen.state.characters.where((c) => c.enabled).length, 6);
  });

  test('槽位够的时候不动手:6 个切到 4.5 全留着', () async {
    final gen = await _withChars(6);
    gen.setModel('NAI 4.5 Full');
    expect(_flags(gen), List.filled(6, true));
  });

  // 切回去**不**自动恢复:停用是用户能看见、能自己勾回来的状态,替他勾回来
  // 反而会把他在小槽位下特意关掉的那几个一起复活。
  test('切回 V5 不自动复原,得用户自己勾', () async {
    final gen = await _withChars(10);
    gen.setModel('NAI 4.5 Full');
    gen.setModel('NAI 5.0 Full');

    expect(_flags(gen), [...List.filled(6, true), ...List.filled(4, false)]);
    expect(maxCharactersOf(gen.state.params.model), 32);
  });

  // 导入面板是先落角色、后落设置,所以那条路也得在落设置时再过一遍。
  test('导入落设置换到小槽位模型:一样收口', () async {
    final gen = await _withChars(10);
    gen.applyImportedSettings(model: 'NAI 4.5 Curated', steps: 28);

    expect(gen.state.params.model, 'NAI 4.5 Curated');
    expect(_flags(gen), [...List.filled(6, true), ...List.filled(4, false)]);
  });
}
