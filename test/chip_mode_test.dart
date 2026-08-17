// 芯片模式(编辑器第二种正文形态)独有的两条文本改写口径。
//
// 芯片流没有光标:加词只能往末尾追,改字只能整名替换。这两件事在文本模式里
// 由 TextField 天然承担,搬到芯片模式后成了显式的文本操作 —— 而**用户的排版**
// (换行分段、已有的逗号)必须在这两条路上原样活下来,否则「加了一个词,整段
// 排版被拍平成一行」这种事一次就能劝退。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';

/// 按名字取第 n 枚词条(改名用例要拿到精确的 Tok)。
Tok _tok(String text, String name) =>
    parseToks(text).firstWhere((t) => t.name == name);

void main() {
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
}
