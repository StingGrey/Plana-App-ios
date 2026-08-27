// 芯片模式(编辑器第二种正文形态)独有的两条文本改写口径。
//
// 芯片流没有光标:加词只能往末尾追,改字只能整名替换。这两件事在文本模式里
// 由 TextField 天然承担,搬到芯片模式后成了显式的文本操作 —— 而**用户的排版**
// (换行分段、已有的逗号)必须在这两条路上原样活下来,否则「加了一个词,整段
// 排版被拍平成一行」这种事一次就能劝退。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';

/// 按名字取第 n 枚词条(改名用例要拿到精确的 Tok)。
Tok _tok(String text, String name) =>
    parseToks(text).firstWhere((t) => t.name == name);

void main() {
  // ⊕ 画在哪儿、以及面板上那颗「移动」能不能点,读的都是这一份判据。
  // 两处各写各的迟早出现「按钮亮着但一个 ⊕ 都没有」。
  group('chipValidGaps:哪些落点是有意义的', () {
    test('单枚:自己两侧那两个间隙是空操作,其余都算', () {
      // 5 枚里选中第 2 枚(下标 1):间隙 1、2 搬过去还是原位
      expect(chipValidGaps({1}, 5), {0, 3, 4, 5});
    });

    test('连续多枚当整块看,块两端同样是空操作', () {
      expect(chipValidGaps({1, 2}, 5), {0, 4, 5});
    });

    // 跳选的那批搬到哪儿都会并拢成一块,所以每个间隙都会改变顺序 ——
    // 一个都不该被判成空操作(这条正是"只按左右相邻是否选中"判不出来的)。
    test('跳选:每个间隙都有意义(搬过去会并拢)', () {
      expect(chipValidGaps({0, 2}, 4), {0, 1, 2, 3, 4});
    });

    test('全选中 / 空选 / 空正文都没得搬', () {
      expect(chipValidGaps({0, 1}, 2), isEmpty);
      expect(chipValidGaps(const {}, 5), isEmpty);
      expect(chipValidGaps({0}, 0), isEmpty);
    });

    test('只有一枚时搬到哪儿都是原位', () {
      expect(chipValidGaps({0}, 1), isEmpty);
    });
  });

  group('appendUnit:尾部输入框的落地口径', () {
    test('空正文直接落词,不带前导逗号', () {
      expect(appendUnit('', '1girl'), '1girl');
      expect(appendUnit('   ', '1girl'), '1girl');
      expect(appendUnit('\n\n', '1girl'), '1girl');
    });

    test('常规追加补 `, `', () {
      expect(appendUnit('1girl', 'smile'), '1girl, smile');
      expect(appendUnit('a, b', 'c'), 'a, b, c');
    });

    test('正文已以逗号收尾:只补空格,不叠出 `,,`', () {
      expect(appendUnit('1girl,', 'smile'), '1girl, smile');
      expect(appendUnit('1girl, ', 'smile'), '1girl, smile');
      expect(appendUnit('1girl，', 'smile'), '1girl， smile'); // 全角原样保留
    });

    // 换行是用户分的段(画师串一行、场景一行)。trim 掉再拼 `, ` 会把两段
    // 并成一行,用户排了半天的版被一次输入抹平。
    test('正文以换行收尾:新词落在新行开头,不把段落拼回一行', () {
      expect(appendUnit('a, b\n', 'c'), 'a, b\nc');
      expect(appendUnit('a, b\n  ', 'c'), 'a, b\nc'); // 行内空白吃掉,换行留着
      expect(appendUnit('a,\n\n', 'c'), 'a,\n\nc'); // 空行(段间距)也留着
    });

    test('空词不改正文;词自身两端空白剪掉', () {
      expect(appendUnit('a', ''), 'a');
      expect(appendUnit('a', '   '), 'a');
      expect(appendUnit('a', '  smile  '), 'a, smile');
    });

    test('追加进来的词是正经的顶层单元(解析得出、算得进定稿)', () {
      final t = appendUnit('1girl, {smile}', '1.2::sky::');
      expect([for (final k in parseToks(t)) k.name], ['1girl', 'smile', 'sky']);
      expect(outputOf(t), '1girl, {smile}, 1.2::sky::');
    });
  });

  group('renameTok:词条栏的行内改名', () {
    test('只换名字,权重/禁用记号原样留着', () {
      const t = '1.2::blue eyes::, smile';
      expect(
        renameTok(t, _tok(t, 'blue eyes'), 'red eyes'),
        '1.2::red eyes::, smile',
      );
      const b = '{smile}, a';
      expect(renameTok(b, _tok(b, 'smile'), 'grin'), '{grin}, a');
      const d = '~off~, a';
      expect(renameTok(d, _tok(d, 'off'), 'on'), '~on~, a');
    });

    test('空名当没改 —— 删词有专门的入口,别从改名掉进去', () {
      const t = 'a, b';
      expect(renameTok(t, _tok(t, 'a'), ''), t);
      expect(renameTok(t, _tok(t, 'a'), '   '), t);
    });

    test('新名两端空白剪掉', () {
      const t = 'a, b';
      expect(renameTok(t, _tok(t, 'a'), '  1girl  '), '1girl, b');
    });

    test('组内改名不动组记号', () {
      const t = '1.5::a, b::, c';
      final out = renameTok(t, _tok(t, 'b'), 'x');
      expect(out, '1.5::a, x::, c');
      // 组还在:x 仍吃 1.5 倍
      expect(parseToks(out).firstWhere((k) => k.name == 'x').effMult, 1.5);
    });
  });

  // 形态是「用惯了哪种」的问题,得跨会话记住;老存档没有这个键时回落文本形态,
  // 不能让升级后的用户莫名其妙换了个编辑器。
  group('EditorSettings.chipMode 持久化', () {
    test('默认文本形态', () {
      expect(const EditorSettings().chipMode, isFalse);
    });

    test('往返不丢', () {
      final on = const EditorSettings().copyWith(chipMode: true);
      expect(EditorSettings.fromJson(on.toJson()).chipMode, isTrue);
      expect(EditorSettings.fromJson(on.toJson()), on);
    });

    test('老存档缺键 → 文本形态', () {
      expect(
        EditorSettings.fromJson(const {'showTranslation': false}).chipMode,
        isFalse,
      );
    });
  });

  // 字号与权重步进从「三五个档位」改成了大范围连续调。读回时**夹住**而不是
  // 回退默认:上下界改动过、或者存进来一个越界值时,把用户调过的偏好整个丢回
  // 默认比夹一下更讨厌。
  group('字号 / 权重步进:范围而非档位', () {
    double fs(Object? v) => EditorSettings.fromJson({'fontSize': v}).fontSize;
    double ws(Object? v) =>
        EditorSettings.fromJson({'weightStep': v}).weightStep;

    test('区间内的任意值原样留着(老档位表外的数不再被打回默认)', () {
      expect(fs(15), 15);
      expect(fs(23), 23);
      expect(ws(0.03), 0.03);
      expect(ws(0.25), 0.25);
    });

    test('越界夹回上下界', () {
      expect(fs(4), EditorSettings.fontSizeMin);
      expect(fs(99), EditorSettings.fontSizeMax);
      expect(ws(0), EditorSettings.weightStepMin);
      expect(ws(9), EditorSettings.weightStepMax);
    });

    test('缺键回默认', () {
      expect(const EditorSettings().fontSize, 16);
      expect(const EditorSettings().weightStep, 0.1);
      expect(EditorSettings.fromJson(const {}).fontSize, 16);
      expect(EditorSettings.fromJson(const {}).weightStep, 0.1);
    });

    test('往返不丢', () {
      final v = const EditorSettings().copyWith(fontSize: 21, weightStep: 0.07);
      expect(EditorSettings.fromJson(v.toJson()), v);
    });
  });
}
