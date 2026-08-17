// 法典词条的角色段藏在与 tags **平级**的 `characterPrompts` 字段里,不在 tags 中。
//
// 现网实测(2026-08-16 全量拉的六部法典):8091 条词条带这个字段,其中 401 条
// tags 本身是空的 —— 内容全在这儿。早先 app 只读 tags,那些词条翻开只有一句话
// 甚至一片空白,「加入提示词」也只进得去那一句,两个角色静悄悄没了。
//
// label 现网分布:char1 8102、char2 4311、char3 653、char4 103、char5 17、
// char6 4、char 2、char2-4 1。所以按 1..6 处理够用,但解析必须容得下不带号的
// `char` 与区间写法 `char2-4`,不能因为认不出一个 label 就把整段丢掉。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';

/// 用户报的那一条(所长 R18,codex_6e699406-5545)的真实形状。
const _raw = {
  'id': 'codex_6e699406-5545',
  'title': '双人合体',
  'tags': 'futanari with female,',
  'characterPrompts': [
    {'label': 'char1', 'prompt': 'girl,2::futanari,shiny skin::,ahoge,'},
    {'label': 'char2', 'prompt': 'girl,2::pink lips,shock::,turning back,'},
  ],
};

void main() {
  group('解析', () {
    test('characterPrompts 落进 characters,tags 不受影响', () {
      final e = CodexEntry.fromJson(_raw);
      expect(e.tags, 'futanari with female,');
      expect(e.characters, hasLength(2));
      expect(e.characters[0].label, 'char1');
      expect(e.characters[1].prompt, contains('turning back'));
    });

    test('空 prompt 的段丢掉(建个空角色卡只会让人以为导入错了)', () {
      final e = CodexEntry.fromJson(const {
        'id': 'x',
        'tags': 'a',
        'characterPrompts': [
          {'label': 'char1', 'prompt': '   '},
          {'label': 'char2', 'prompt': 'b'},
        ],
      });
      expect(e.characters, hasLength(1));
      expect(e.characters.single.label, 'char2');
    });

    test('字段缺失 / 类型不对一律当没有,不抛', () {
      expect(CodexEntry.fromJson(const {'id': 'x'}).characters, isEmpty);
      expect(
        CodexEntry.fromJson(const {'id': 'x', 'characterPrompts': 'oops'})
            .characters,
        isEmpty,
      );
    });
  });

  group('label 语义', () {
    test('charN → 第 N 个角色位', () {
      expect(const CodexCharacter('char1', 'p').slots, [1]);
      expect(const CodexCharacter('char6', 'p').slots, [6]);
      expect(const CodexCharacter('char1', 'p').display, '角色 1');
    });

    // 全站 2 条:不带号 = 就一个角色
    test('不带号的 char 当第一个', () {
      expect(const CodexCharacter('char', 'p').slots, [1]);
    });

    // 全站 1 条:一段管好几个角色位
    test('区间 char2-4 展开成 2,3,4', () {
      expect(const CodexCharacter('char2-4', 'p').slots, [2, 3, 4]);
      expect(const CodexCharacter('char2-4', 'p').display, '角色 2-4');
    });

    test('区间反了 / 离谱只认起点,不生成一串卡', () {
      expect(const CodexCharacter('char4-2', 'p').slots, [4]);
      expect(const CodexCharacter('char1-99', 'p').slots, [1]);
    });

    test('认不出的 label 不占角色位,但原样显示(内容仍然看得到)', () {
      const c = CodexCharacter('主角', 'p');
      expect(c.slots, isEmpty);
      expect(c.display, '主角');
    });
  });

  group('fullText:展示与复制的口径', () {
    test('公共部分 + 各角色段,带标题分段', () {
      final t = CodexEntry.fromJson(_raw).fullText;
      expect(t, startsWith('futanari with female,'));
      expect(t, contains('角色 1'));
      expect(t, contains('角色 2'));
      expect(t, contains('ahoge'));
      expect(t, contains('turning back'));
    });

    // 401 条是这种:tags 空,内容全在角色段。以前它们翻开是一片空白
    test('tags 为空时不留空行,直接从角色段开始', () {
      final e = CodexEntry.fromJson(const {
        'id': 'x',
        'tags': '',
        'characterPrompts': [
          {'label': 'char1', 'prompt': 'girl'},
        ],
      });
      expect(e.fullText, '角色 1\ngirl');
      expect(e.fullText.isNotEmpty, isTrue, reason: '空的话详情页翻不了面');
    });

    test('没有角色段时就是 tags 本身', () {
      final e = CodexEntry.fromJson(const {'id': 'x', 'tags': '1girl, smile'});
      expect(e.fullText, '1girl, smile');
    });
  });

  // 收藏夹存的是词条快照。漏了这个字段,收藏过的多角色词条再打开会缺主体 ——
  // 而那正是最值得收藏的那一批。
  test('toJson 带上 characterPrompts,收藏往返不丢', () {
    final e = CodexEntry.fromJson(_raw);
    final back = CodexEntry.fromJson(e.toJson());
    expect(back.characters, hasLength(2));
    expect(back.characters[1].label, 'char2');
    expect(back.fullText, e.fullText);
  });
}
