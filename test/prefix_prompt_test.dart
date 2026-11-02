import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/direct_agent.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';

void main() {
  const rules = [
    PresetRule(name: 'role', content: 'ROLE'),
    PresetRule(name: 'comic', content: 'COMIC', when: 'comic'),
    PresetRule(name: 'output', content: 'OUTPUT'),
  ];

  group('前置提示词', () {
    test('空的不加段,原样返回', () {
      expect(withPrefix(rules, ''), same(rules));
      expect(withPrefix(rules, '  \n '), same(rules));
    });

    test('排在第一段,首尾空白去掉', () {
      final out = withPrefix(rules, '\n  回复用中文  \n');
      expect(out.first.name, kPrefixRuleName);
      expect(out.first.content, '回复用中文');
      expect(out.first.when, '');
      expect(out.skip(1), rules);
    });

    test('挂工具层之后再加,仍在最前,工具层照旧跟在 role 后面', () {
      final out = withPrefix(withToolLayer(rules, 'TOOLS'), 'PREFIX');
      expect(
        [for (final r in out) r.name],
        [kPrefixRuleName, 'role', kToolLayerName, 'comic', 'output'],
      );
    });

    test('自定义接口的系统提示以它开头,且不随模式变', () {
      String system(List<String>? modes) => directSystemPrompt(
        rules: withPrefix(rules, 'PREFIX'),
        modes: modes,
        outputFormat: 'FORMAT',
        toolsBlock: 'TOOLS',
      );
      expect(system(const []), startsWith('PREFIX\n\nROLE'));
      expect(system(const ['comic']), startsWith('PREFIX\n\nROLE'));
      expect(system(const ['comic']), contains('COMIC'));
    });

    test('设置存取:来回一致,缺键或脏数据当没写', () {
      const s = AssistantSettings(prefixPrompt: '先说构思\n再给提示词');
      expect(
        AssistantSettings.fromJson(s.toJson()).prefixPrompt,
        s.prefixPrompt,
      );
      expect(AssistantSettings.fromJson(const {}).prefixPrompt, '');
      expect(
        AssistantSettings.fromJson(const {'prefixPrompt': 42}).prefixPrompt,
        '',
      );
    });
  });
}
