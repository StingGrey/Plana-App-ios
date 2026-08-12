// 法典 charN 多角色标记的拆分。
//
// 用例形状取自现网数据(data/NAI_NSFW.json 里约 21% 的词条长这样):
//   "公共部分,\nchar1：girl,…,\nchar2：boy,…"
// 不拆的话 `char1` `char2` 会作为字面 tag 发给 NAI —— 它不认这个约定,
// 只会把它们当普通词,角色特征全糊在一起。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/inspiration/codex/codex_char_split.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('现网形状:中文冒号 + 换行,首尾逗号都削干净', () {
    final r = splitCodexCharacters(
      'close-up,from side,1man,1girl,\n'
      'char1：girl,body blush,thick thighs,\n'
      'char2：boy,muscular male,standing,',
    );
    expect(r.base, 'close-up,from side,1man,1girl');
    expect(r.characters.map((c) => c.index), [1, 2]);
    expect(r.characters[0].positive, 'girl,body blush,thick thighs');
    expect(r.characters[1].positive, 'boy,muscular male,standing');
    expect(r.characters[0].negative, '');
  });

  test('英文冒号、无换行也认', () {
    final r = splitCodexCharacters('base,char1:a,b,char2:c');
    expect(r.base, 'base');
    expect(r.characters.map((c) => c.positive), ['a,b', 'c']);
  });

  test('方括号形式:同号的 +/- 合成一张卡', () {
    final r = splitCodexCharacters('base,[char1+]a,b,[char1-]bad quality,');
    expect(r.characters, hasLength(1));
    expect(r.characters.single.positive, 'a,b');
    expect(r.characters.single.negative, 'bad quality');
  });

  test('编号原样保留,不重排', () {
    // 词条只写了 char2 时,卡就该叫「角色 2」—— 改成 1 会和词条对不上号
    final r = splitCodexCharacters('base,char2：only');
    expect(r.characters.single.index, 2);
  });

  test('公共部分可以为空(词条上来就是 char1)', () {
    final r = splitCodexCharacters('char1：a,char2：b');
    expect(r.base, isEmpty);
    expect(r.characters, hasLength(2));
  });

  test('只有负向没正向的角色丢掉', () {
    // 建一张空正向的卡只会让人以为导入出了错
    final r = splitCodexCharacters('base,[char1-]bad,');
    expect(r.hasCharacters, isFalse);
    expect(r.base, 'base');
  });

  test('大小写不敏感', () {
    final r = splitCodexCharacters('base,CHAR1：a,[Char2+]b');
    expect(r.characters.map((c) => c.index), [1, 2]);
  });

  test('没有标记就原样返回', () {
    const raw = '1girl, solo, masterpiece';
    final r = splitCodexCharacters(raw);
    expect(r.hasCharacters, isFalse);
    expect(r.base, raw);
    // 「character」这类词里含 char,但不带编号+冒号,不该被误认
    expect(
      splitCodexCharacters('character sheet, chart').hasCharacters,
      isFalse,
    );
  });

  group('落地到角色卡', () {
    ProviderContainer makeContainer() {
      final stores = AppStores.ephemeral();
      final c = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(() async {
        c.dispose();
        stores.flushNow();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      return c;
    }

    test('超出上限的丢掉,并如实报出加了几张', () {
      final c = makeContainer();
      final n = c.read(generateProvider.notifier);
      // 先占掉 4 张
      for (var i = 0; i < 4; i++) {
        n.addCharacter();
      }
      final added = n.addCharactersFilled([
        for (var i = 1; i <= 3; i++)
          (name: '角色 $i', positive: 'p$i', negative: ''),
      ]);
      expect(added, 2); // 只塞得下 2 张
      expect(c.read(generateProvider).characters, hasLength(kMaxCharacters));
      expect(c.read(generateProvider).characters.last.positive, 'p2');
      // 满了之后再加一张都进不去
      expect(
        n.addCharactersFilled([(name: 'x', positive: 'y', negative: '')]),
        0,
      );
    });

    test('内容与负向一并落进卡片,并展开角色面板', () {
      final c = makeContainer();
      final n = c.read(generateProvider.notifier);
      expect(
        n.addCharactersFilled([
          (name: '角色 1', positive: 'girl', negative: 'bad hands'),
        ]),
        1,
      );
      final ch = c.read(generateProvider).characters.single;
      expect(ch.name, '角色 1');
      expect(ch.positive, 'girl');
      expect(ch.negative, 'bad hands');
      expect(c.read(generateProvider).openPanels, contains(Panel.characters));
    });
  });
}
