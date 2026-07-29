// NaiT5Tokenizer 与 web 端 @huggingface/tokenizers@0.1.3 的逐数对照。
// 期望值由 scratchpad 的 truth.mjs 用 web 同款包 + 同一份词表生成
// (web countTokens 口径:去 []{} 与 ::权重记号后 encode,含结尾 </s>)。
// 用例字符串里的不可见字符一律 \u 转义,与生成脚本码点级一致。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/nai_tokenizer.dart';

void main() {
  late NaiT5Tokenizer tok;

  setUpAll(() {
    tok = NaiT5Tokenizer.parse(
      File('assets/t5_tokenizer.json').readAsStringSync(),
    );
  });

  test('countTokens 与 web 实现逐数一致', () {
    final cases = <(String, int)>[
      ('', 0),
      ('   ', 0),
      ('1girl, solo', 5),
      ('1girl, solo, blue sky, cherry blossoms, detailed background', 15),
      ('masterpiece, best quality, amazing quality, very aesthetic, absurdres', 15),
      ('1.2::very aesthetic::, {{tree}}, [old style], (detailed face)', 15),
      ('long_hair, looking_at_viewer, short_twintails', 18),
      ('a girl standing in the rain at night, cinematic lighting, ultra-detailed, 8k wallpaper', 24),
      ('\u{96e8}\u{306e}\u{4e2d}\u{306e}\u{5c11}\u{5973}\u{3001}\u{5098}\u{3001}\u{591c}', 3),
      ('\u{4f60}\u{597d}\u{ff0c}\u{4e16}\u{754c}\u{ff0c}\u{4e00}\u{4e2a}\u{5973}\u{5b69}', 7),
      ('\u{ff26}\u{ff55}\u{ff4c}\u{ff4c}\u{ff57}\u{ff49}\u{ff44}\u{ff54}\u{ff48}\u{3000}\u{ff21}\u{ff22}\u{ff23}\u{ff01}', 6),
      ('caf\u{e9} r\u{e9}sum\u{e9} na\u{ef}ve', 10),
      ('cafe\u{301}', 2),
      ('emoji \u{1f3a8}\u{1f338} test', 8),
      ('multiple   spaces\u{9}and\u{a}newlines  end', 7),
      ('X X X', 7),
      ('\u{2581}literal metaspace', 4),
      ('::', 0),
      ('-1.5::weighted tag::, 0.8::another::', 7),
      ('artist:wlop, year 2024', 9),
      ('no lineart, smooth shading, soft lighting, 1girl, white hair, long hair, blue eyes, school uniform, sitting, window, classroom, sunset, dutch angle, depth of field, best quality, amazing quality', 48),
      ('nsfw, lowres, bad anatomy, bad hands, text, error, missing fingers, extra digit, fewer digits, cropped, worst quality, low quality, normal quality, jpeg artifacts, signature, watermark, username, blurry', 64),
      ('foo,bar,baz', 9),
      ('Pok\u{e9}mon \u{30dd}\u{30b1}\u{30e2}\u{30f3} \u{5b9d}\u{53ef}\u{68a6}', 6),
      ('~rating:general~, tag', 10),
      ('a\u{a0}b', 5),
      ('a\u{3000}b', 5),
      ('\u{fb01}sh \u{3299} \u{bd}', 7),
      ('a\u{ff5e}b', 5),
      ('\u{ff71}\u{ff72}\u{ff73}, \u{2460}\u{2461}\u{2462}', 6),
      ('\u{ff76}\u{ff9e}\u{ff77}\u{ff9e}\u{ff78}\u{ff9e}', 3),
      ('\u{1d525}\u{1d522}\u{1d529}\u{1d529}\u{1d52c} \u{1d568}\u{1d560}\u{1d563}\u{1d55d}\u{1d555}', 3),
      ('\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466} family', 10),
      ('\u{1f3a8}', 3),
      ('zero\u{200b}width\u{200d}joined', 4),
      ('   leading trailing   ', 4),
      ('tab\u{9}here\u{a}newline', 5),
      ('mixed \u{6df7}\u{5408} mixed, \u{30bf}\u{30b0} tag', 9),
      ('very aesthetic, masterpiece, no text, 1girl, cowboy shot, from side, wind, floating hair, ocean, sunset, orange sky, clouds, waves, silhouette, backlighting, lens flare, chromatic aberration, film grain', 52),
    ];
    expect(cases.length, 39, reason: '用例应与 truth.mjs 同步');
    for (final (text, expected) in cases) {
      expect(tok.countTokens(text), expected, reason: '输入: "$text"');
    }
  });

  test('缓存命中返回同值', () {
    const s = '1girl, solo, blue sky';
    final a = tok.countTokens(s);
    expect(tok.countTokens(s), a);
  });

  test('totalPromptTokens 口径:各段独立计数求和', () {
    const main = '1girl, solo';
    const char = 'red eyes, smile';
    const preset = 'masterpiece, best quality';
    final want =
        tok.countTokens(main) + tok.countTokens(char) + tok.countTokens(preset);
    expect(
      totalPromptTokens(tok, main: main, parts: const [char], preset: preset),
      want,
    );
    // 空段:countTokens 空串为 0,不额外贡献 </s>
    expect(totalPromptTokens(tok, main: main), tok.countTokens(main));
  });

  test('totalPromptTokens 未就绪时退回 ÷2.2 粗估', () {
    expect(
      totalPromptTokens(null, main: 'abcde', preset: 'xyz'),
      ('xyz, abcde'.length / 2.2).round(),
    );
  });
}
