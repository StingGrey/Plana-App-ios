import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/param_help.dart';

/// 参数说明的文案是从 web 桌面端整段复制过来的,靠行前缀分区。
/// 这里锁住解析规则 —— 前缀写法一变(比如 💡 后少个空格),
/// 提示会静悄悄掉进正文里,界面上看不出错。
void main() {
  test('· 开头进要点,💡 开头进使用提示', () {
    const h = ParamHelp('T', '开场白。\n· 要点一\n· 要点二\n💡 提示一');
    expect(h.points, [(false, '开场白。'), (true, '要点一'), (true, '要点二')]);
    expect(h.tips, ['提示一']);
  });

  test('💡 后没有空格照样收进提示区', () {
    // web 的 Noise Schedule 就是这么写的:`💡建议保持默认 karras`
    expect(Help.noiseSchedule.tips, ['建议保持默认 karras']);
    expect(
      Help.noiseSchedule.points.map((p) => p.$2),
      isNot(contains(startsWith('💡'))),
    );
  });

  test('空行不产生空条目', () {
    const h = ParamHelp('T', '一。\n\n  \n· 二\n');
    expect(h.points, [(false, '一。'), (true, '二')]);
    expect(h.tips, isEmpty);
  });

  test('每条说明都有标题和正文,提示不混进正文', () {
    const all = [
      Help.img2imgStrength,
      Help.img2imgNoise,
      Help.vibeStrength,
      Help.infoExtracted,
      Help.charRefStrength,
      Help.fidelity,
      Help.steps,
      Help.cfg,
      Help.varietyPlus,
      Help.sampler,
      Help.noiseSchedule,
      Help.seed,
      Help.cfgRescale,
    ];
    for (final h in all) {
      expect(h.title, isNotEmpty);
      expect(h.points, isNotEmpty, reason: '${h.title} 没有正文');
      for (final (_, text) in h.points) {
        expect(text, isNot(startsWith('💡')), reason: '${h.title} 的提示漏进正文');
        expect(text, isNot(startsWith('·')), reason: '${h.title} 的项目符号没剥掉');
      }
    }
  });
}
