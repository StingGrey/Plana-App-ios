import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/generate/anima_nl.dart';

const _s1 =
    'Plana leans in from behind Arona, resting her chin on the shorter '
    "girl's shoulder.";
const _s2 = 'Warm rim light falls across both of them from the window.';

void main() {
  group('句子 ↔ 正向词', () {
    test('追加到末尾:tag 后用逗号接,句子后用空格接', () {
      final a = appendNlToPrompt('1girl, plana', _s1);
      expect(a, '1girl, plana, $_s1');
      // anima 的写法约定:句子之间不夹逗号
      expect(appendNlToPrompt(a, _s2), '1girl, plana, $_s1 $_s2');
    });

    test('空正向词直接就是这一段;末尾的逗号不重复', () {
      expect(appendNlToPrompt('', _s1), _s1);
      expect(appendNlToPrompt('1girl,  ', _s1), '1girl, $_s1');
    });

    test('已在场不重复追加(空白差异照样认)', () {
      final p = appendNlToPrompt('1girl', _s1);
      expect(appendNlToPrompt(p, _s1), p);
      // 用户在编辑器里换了行/多敲空格,仍算在场
      final wrapped = p.replaceFirst('leans in from', 'leans in\n  from');
      expect(promptHasNl(wrapped, _s1), isTrue);
      expect(appendNlToPrompt(wrapped, _s1), wrapped);
    });

    test('移除只收接缝,句外原文不动', () {
      const base = '1girl, plana,\nblue sky';
      final p = appendNlToPrompt(base, _s1);
      expect(removeNlFromPrompt(p, _s1), base);

      // 夹在中间的一段:两侧接回一个逗号
      final mid = '1girl, $_s1, blue sky';
      expect(removeNlFromPrompt(mid, _s1), '1girl, blue sky');

      // 两段句子,只走一段
      final two = appendNlToPrompt(appendNlToPrompt('1girl', _s1), _s2);
      expect(removeNlFromPrompt(two, _s1), '1girl, $_s2');
      expect(removeNlFromPrompt(two, _s2), '1girl, $_s1');
    });

    test('整串只有这一段时清空;不在场原样返回', () {
      expect(removeNlFromPrompt(_s1, _s1), '');
      expect(removeNlFromPrompt('1girl', _s1), '1girl');
    });

    test('句内逗号不被当 tag 边界(与触发词那套口径的分水岭)', () {
      final p = appendNlToPrompt('1girl', _s1);
      expect(promptHasNl(p, _s1), isTrue);
      // 别的句子不算在场:必须整段匹配
      expect(promptHasNl(p, 'Arona holds a tablet against her chest.'), isFalse);
    });

    test('正则元字符原样匹配,不当模式解释', () {
      const tricky = 'Light (soft) falls on her face.';
      final p = appendNlToPrompt('1girl', tricky);
      expect(promptHasNl(p, tricky), isTrue);
      expect(removeNlFromPrompt(p, tricky), '1girl');
    });
  });

  group('唯一插入点', () {
    test('整段进整段出:不留半截描述', () {
      const st = AnimaNlState(result: AnimaNlResult(text: '$_s1 $_s2'));
      final p = appendNlToPrompt('1girl, plana', st.fullText);
      expect(p, '1girl, plana, $_s1 $_s2');
      expect(promptHasNl(p, st.fullText), isTrue);
      expect(removeNlFromPrompt(p, st.fullText), '1girl, plana');
    });

    test('结果里的换行/多余空白在入口就压平', () {
      const st = AnimaNlState(result: AnimaNlResult(text: '  $_s1\n  $_s2 '));
      expect(st.fullText, '$_s1 $_s2');
      expect(const AnimaNlState().fullText, '');
    });
  });

  group('响应解析', () {
    test('取 text / note_zh,首尾空白剥掉', () {
      final r = AnimaNlResult.fromJson({
        'text': '  $_s1 ',
        'note_zh': ' 讲清了两人的姿势与互动 ',
      });
      expect(r.text, _s1);
      expect(r.noteZh, '讲清了两人的姿势与互动');
    });

    test('字段缺失 / 形状不对不炸', () {
      expect(AnimaNlResult.fromJson({}).text, '');
      expect(AnimaNlResult.fromJson({'text': 42}).text, '42');
      expect(AnimaNlResult.fromJson({'note_zh': null}).noteZh, '');
    });
  });

  group('模块状态存档', () {
    test('往返保留补充要求 / 预设 / 结果', () {
      const st = AnimaNlState(
        extra: '强调雨天湿透的质感',
        mode: AnimaNlMode.characters,
        result: AnimaNlResult(text: _s1, noteZh: '讲清了两人的互动'),
      );
      final back = AnimaNlState.fromJson(st.toJson());
      expect(back.extra, st.extra);
      expect(back.mode, AnimaNlMode.characters);
      expect(back.result!.text, _s1);
      expect(back.result!.noteZh, '讲清了两人的互动');
      // 临时态不落盘
      expect(back.running, isNull);
      expect(back.error, '');
    });

    test('存档缺字段 / 预设改名回落默认', () {
      final back = AnimaNlState.fromJson({'mode': 'nope'});
      expect(back.mode, isNull);
      expect(back.result, isNull);
      expect(back.extra, '');
    });
  });
}
