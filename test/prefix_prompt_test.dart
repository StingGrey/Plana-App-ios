import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/domain/turn_request.dart';
import 'package:plana_app/features/assistant/llm/llm_provider.dart';
import 'package:plana_app/features/assistant/presets/preset_rule.dart';
import 'package:plana_app/features/assistant/runtime/local_runtime.dart';
import 'package:plana_app/features/assistant/runtime/prompt_composer.dart';

/// 记下每一跳的请求,回一句话。
class _EchoLlm implements LlmProvider {
  final requests = <LlmRequest>[];

  @override
  LlmCapabilities get capabilities =>
      const LlmCapabilities(streaming: true, thinking: true);

  @override
  String? thinkNote(ThinkLevel level) => null;

  @override
  Stream<LlmText> chat(
    LlmRequest request, {
    required http.Client client,
    bool stream = true,
    Duration? timeout,
  }) async* {
    requests.add(request);
    yield (text: '好的', reasoning: '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rules = [
    PresetRule(name: 'role', content: 'ROLE'),
    PresetRule(name: 'comic', content: 'COMIC', when: 'comic'),
    PresetRule(name: 'output', content: 'OUTPUT'),
  ];

  group('前置提示词', () {
    String system(String prefix, List<String> modes) => composeSystemPrompt(
      rules: rules,
      modes: modes,
      prefix: prefix,
      toolLayer: 'TOOLS',
      outputFormat: 'FORMAT',
    );

    test('空的不加段,和没写一样', () {
      final none = composeSystemPrompt(
        rules: rules,
        modes: const [],
        toolLayer: 'TOOLS',
        outputFormat: 'FORMAT',
      );
      expect(system('', const []), none);
      expect(system('  \n ', const []), none);
    });

    test('排在系统提示最前面,首尾空白去掉', () {
      expect(system('\n  回复用中文  \n', const []), startsWith('回复用中文\n\nROLE'));
    });

    test('工具层照旧跟在 role 后面', () {
      final s = system('PREFIX', const []);
      expect(s.indexOf('PREFIX'), lessThan(s.indexOf('ROLE')));
      expect(s.indexOf('ROLE'), lessThan(s.indexOf('TOOLS')));
    });

    test('不随模式变', () {
      expect(system('PREFIX', const []), startsWith('PREFIX\n\nROLE'));
      expect(system('PREFIX', const ['comic']), startsWith('PREFIX\n\nROLE'));
      expect(system('PREFIX', const ['comic']), contains('COMIC'));
    });

    test('设置存取:来回一致,缺键或脏数据当没写,空的不落盘', () {
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
      expect(
        const AssistantSettings().toJson(),
        isNot(contains('prefixPrompt')),
      );
    });

    test('跑一轮时发出去的系统提示以它开头', () async {
      final llm = _EchoLlm();
      await LocalAgentRuntime(provider: llm, tools: const [])
          .run(
            const AgentTurnRequest(
              userText: '画一张',
              imageModel: 'nai_v45_full',
              customRules: rules,
              prefixPrompt: '  PREFIX  ',
              stream: false,
            ),
          )
          .drain<void>();
      expect(llm.requests.single.system, startsWith('PREFIX\n\nROLE'));
    });
  });
}
