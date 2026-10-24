// 创作页 NSFW 开关:`nsfw` 夹在预设前缀与主提示词之间(见 withNsfwTag)。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';

const _prefix = PromptPreset(
  id: 'custom_1',
  name: '我的档',
  positive: 'my quality',
  negative: 'my junk',
);

/// 同 GenerationNotifier._applyPreset 的顺序:先拼 nsfw,预设再叠上去。
String _send(String prompt, PromptPreset? p, {bool nsfw = true}) =>
    applyPromptPreset(
      p,
      withNsfwTag(prompt, on: nsfw, preset: p),
      '',
    ).positive;

void main() {
  test('前缀档:预设, nsfw, 主提示词', () {
    expect(_send('1girl, smile', _prefix), 'my quality, nsfw, 1girl, smile');
  });

  test('后缀档 / 无预设:nsfw 落在主提示词最前', () {
    final v5 = kDefaultPromptPresets.firstWhere((p) => p.id == 'v5-standard');
    expect(_send('1girl', v5), 'nsfw, 1girl, ${v5.positive}');
    expect(_send('1girl', null), 'nsfw, 1girl');
  });

  test('关着不动;主提示词为空只剩 nsfw,不留悬空逗号', () {
    expect(_send('1girl', _prefix, nsfw: false), 'my quality, 1girl');
    expect(withNsfwTag('', on: true), 'nsfw');
    expect(_send('', _prefix), 'my quality, nsfw');
  });

  test('已经写了 nsfw(主提示词或预设里)就不再拼', () {
    expect(withNsfwTag('1girl, NSFW , smile', on: true), '1girl, NSFW , smile');
    expect(withNsfwTag('1girl，nsfw', on: true), '1girl，nsfw');
    final withTag = _prefix.copyWith(positive: 'my quality, nsfw');
    expect(_send('1girl', withTag), 'my quality, nsfw, 1girl');
    // 只认独立的那个 tag,不是子串
    expect(withNsfwTag('nsfw_logo', on: true), 'nsfw, nsfw_logo');
  });
}
