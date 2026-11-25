// 助手思考过程(iOS 版补的):各家思考字段的收发、思考随消息落盘、多跳思考拼进结果,
// 以及 OpenAI Responses 报文与 iOS 旧存档的兼容。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Icons, IconData;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/domain/agent_event.dart';
import 'package:plana_app/features/assistant/domain/conversation.dart';
import 'package:plana_app/features/assistant/domain/turn_request.dart';
import 'package:plana_app/features/assistant/llm/http_provider.dart';
import 'package:plana_app/features/assistant/llm/llm_provider.dart';
import 'package:plana_app/features/assistant/presets/preset_rule.dart';
import 'package:plana_app/features/assistant/protocol/reply_parser.dart';
import 'package:plana_app/features/assistant/runtime/local_runtime.dart';
import 'package:plana_app/features/assistant/runtime/prompt_assets.dart';
import 'package:plana_app/features/assistant/tools/agent_tool.dart';
import 'package:plana_app/features/assistant/tools/tool_context.dart';

CustomEndpoint _ep(
  AgentApiFormat f, {
  String model = 'm1',
  String base = 'http://api.test/v1',
  bool responses = false,
}) => CustomEndpoint(
  id: 'e1',
  name: 'test',
  format: f,
  baseUrl: base,
  apiKey: 'k',
  model: model,
  responses: responses,
);

HttpLlmProvider _llm(
  AgentApiFormat f, {
  String model = 'm1',
  String base = 'http://api.test/v1',
  bool responses = false,
}) => llmProviderFor(_ep(f, model: model, base: base, responses: responses));

HttpLlmProvider _responses([String model = 'm1']) =>
    _llm(AgentApiFormat.openai, model: model, responses: true);

String _sse(List<String> frames) => frames.map((f) => 'data: $f\n\n').join();

MockClient _client(
  String body, {
  String contentType = 'text/event-stream',
  void Function(http.BaseRequest req, String body)? onRequest,
}) => MockClient.streaming((req, bodyStream) async {
  onRequest?.call(req, utf8.decode(await bodyStream.toBytes()));
  return http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    200,
    headers: {'content-type': contentType},
  );
});

Future<List<LlmText>> _run(
  http.Client c,
  HttpLlmProvider p, {
  bool stream = true,
}) => p
    .chat(
      const LlmRequest(
        system: 'sys',
        messages: [(role: 'user', content: '画一张', images: [])],
      ),
      client: c,
      stream: stream,
      timeout: const Duration(seconds: 5),
    )
    .toList();

/// 按顺序吐预先写好的回复,不发网络请求。
class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(this.replies);

  final List<LlmText> replies;
  var _i = 0;

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
    yield replies[_i++];
  }
}

class _FakeTool extends AgentTool {
  const _FakeTool();

  @override
  String get name => 'fake_lookup';

  @override
  String get label => 'fake';

  @override
  IconData get icon => Icons.search;

  @override
  List<ToolParam> get params => const [ToolParam('q', 'string')];

  @override
  Future<String> guidance() async => '查点什么';

  @override
  Future<ToolOutcome> call(ToolContext ctx, Map<String, dynamic> args) async =>
      const ToolOutcome(['x']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('思考标签的几种写法', () {
    final texts = PromptTexts.parse(
      File('assets/prompts/texts.yaml').readAsStringSync(),
    );

    test('<think> / <thinking> / <thought> 都剥掉,收尾得同名', () {
      for (final tag in ['Think', 'think', 'thinking', 'thought']) {
        expect(
          parseReply('<$tag>先想想</$tag>好的', texts).reply,
          '好的',
          reason: tag,
        );
        final v = streamView('<$tag>先想想</$tag>好的');
        expect(v.think, '先想想', reason: tag);
        expect(v.body, '好的', reason: tag);
      }
      // 里面提到别的收尾标签不算收尾
      final v = streamView('<think>别把 </thought> 当收尾</think>好的');
      expect(v.think, '别把 </thought> 当收尾');
      expect(v.body, '好的');
      expect(streamView('好的 <thinkin').body, '好的');
    });
  });

  group('非流式响应里的思考', () {
    test('形状不对是空串,不崩', () {
      for (final p in [
        _llm(AgentApiFormat.openai),
        _llm(AgentApiFormat.google),
        _llm(AgentApiFormat.anthropic),
        _responses(),
      ]) {
        expect(p.parseResponseReasoning(null), '');
        expect(p.parseResponseReasoning(const {}), '');
      }
    });

    test('OpenAI 兼容 / Claude / Gemini 各取各的', () {
      expect(
        _llm(AgentApiFormat.openai).parseResponseReasoning(const {
          'choices': [
            {
              'message': {'content': '喵', 'reasoning_content': '想'},
            },
          ],
        }),
        '想',
      );
      expect(
        _llm(AgentApiFormat.anthropic).parseResponseReasoning(const {
          'content': [
            {'type': 'thinking', 'thinking': '想'},
            {'type': 'text', 'text': '喵'},
          ],
        }),
        '想',
      );
      const gemini = {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': '先想想', 'thought': true},
                {'text': '喵'},
              ],
            },
          },
        ],
      };
      expect(_llm(AgentApiFormat.google).parseResponse(gemini), '喵');
      expect(_llm(AgentApiFormat.google).parseResponseReasoning(gemini), '先想想');
    });

    test('Responses:正文在 message 里,思考摘要在 reasoning 里', () {
      const body = {
        'output': [
          {
            'type': 'reasoning',
            'summary': [
              {'type': 'summary_text', 'text': '**看需求**'},
              {'type': 'summary_text', 'text': '**定画面**'},
            ],
          },
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': '喵'},
            ],
          },
        ],
      };
      expect(_responses().parseResponse(body), '喵');
      expect(_responses().parseResponseReasoning(body), '**看需求**\n\n**定画面**');
    });

    test('Mistral:content 是分段数组,thinking 段不进正文', () {
      const body = {
        'choices': [
          {
            'message': {
              'content': [
                {
                  'type': 'thinking',
                  'thinking': [
                    {'type': 'text', 'text': '想'},
                  ],
                },
                {'type': 'text', 'text': '喵'},
              ],
            },
          },
        ],
      };
      expect(_llm(AgentApiFormat.openai).parseResponse(body), '喵');
      expect(_llm(AgentApiFormat.openai).parseResponseReasoning(body), '想');
    });
  });

  group('流式增量里的思考', () {
    test('OpenRouter:reasoning 空着时从 reasoning_details 取', () {
      final p = _llm(AgentApiFormat.openai);
      expect(
        p.parseDelta({
          'choices': [
            {
              'delta': {
                'reasoning': '',
                'reasoning_details': [
                  {'type': 'reasoning.summary', 'summary': '摘要'},
                  {'type': 'reasoning.encrypted', 'data': 'xx'},
                ],
              },
            },
          ],
        }),
        (text: '', reasoning: '摘要'),
      );
      // 两样都有时只取 reasoning,不重复
      expect(
        p.parseDelta({
          'choices': [
            {
              'delta': {
                'reasoning': '想',
                'reasoning_details': [
                  {'type': 'reasoning.text', 'text': '想'},
                ],
              },
            },
          ],
        }),
        (text: '', reasoning: '想'),
      );
    });

    test('Mistral:delta.content 是分段数组', () {
      expect(
        _llm(AgentApiFormat.openai).parseDelta({
          'choices': [
            {
              'delta': {
                'content': [
                  {
                    'type': 'thinking',
                    'thinking': [
                      {'type': 'text', 'text': '想'},
                    ],
                  },
                ],
              },
            },
          ],
        }),
        (text: '', reasoning: '想'),
      );
    });

    test('Responses:正文、摘要、开源模型原文三种增量', () {
      final p = _responses();
      expect(
        p.parseDelta({'type': 'response.output_text.delta', 'delta': '好的'}),
        (text: '好的', reasoning: ''),
      );
      expect(
        p.parseDelta({
          'type': 'response.reasoning_summary_text.delta',
          'delta': '想',
        }),
        (text: '', reasoning: '想'),
      );
      expect(
        p.parseDelta({'type': 'response.reasoning_text.delta', 'delta': '想'}),
        (text: '', reasoning: '想'),
      );
      // 第二段摘要开头空一行;第一段不空
      expect(
        p.parseDelta({
          'type': 'response.reasoning_summary_part.added',
          'summary_index': 1,
        }).reasoning,
        '\n\n',
      );
      expect(
        p.parseDelta({
          'type': 'response.reasoning_summary_part.added',
          'summary_index': 0,
        }).reasoning,
        '',
      );
      expect(p.parseDelta({'type': 'response.completed'}), (
        text: '',
        reasoning: '',
      ));
    });
  });

  group('思考等级 → 请求字段', () {
    test('Claude 老模型(4.5 及以前):关 = 不带 thinking;开着预算不低于 1024 且递增', () {
      for (final model in [
        'claude-sonnet-4-5',
        'claude-haiku-4-5-20251001',
        'claude-opus-4-1-20250805',
        'claude-sonnet-4-20250514',
        'claude-3-7-sonnet-latest',
        'anthropic/claude-sonnet-4.5',
      ]) {
        final p = _llm(AgentApiFormat.anthropic, model: model);
        expect(p.thinkFields(ThinkLevel.off), isEmpty, reason: model);
        expect(p.thinkFields(ThinkLevel.auto), isEmpty, reason: model);
        var prev = 0;
        for (final l in [
          ThinkLevel.low,
          ThinkLevel.medium,
          ThinkLevel.high,
          ThinkLevel.ultra,
        ]) {
          final t = p.thinkFields(l)['thinking'] as Map;
          expect(t['type'], 'enabled', reason: model);
          final b = t['budget_tokens'] as int;
          expect(b, greaterThanOrEqualTo(1024));
          expect(b, greaterThan(prev));
          prev = b;
        }
      }
    });

    test('Claude 新模型:自适应思考 + 力度,不发 budget_tokens(4.7 起是 400)', () {
      for (final model in [
        'claude-opus-4-6',
        'claude-opus-4-8',
        'claude-sonnet-5-5',
        'claude-fable-5-1',
        // 认不出的别名按新的走
        'my-claude',
      ]) {
        final f = _llm(
          AgentApiFormat.anthropic,
          model: model,
        ).thinkFields(ThinkLevel.high);
        expect(f['thinking'], {
          'type': 'adaptive',
          'display': 'summarized',
        }, reason: model);
        expect(f['output_config'], {'effort': 'high'}, reason: model);
        expect(jsonEncode(f), isNot(contains('budget_tokens')), reason: model);
      }
      expect(
        (_llm(
              AgentApiFormat.anthropic,
              model: 'claude-opus-5-5',
            ).thinkFields(ThinkLevel.ultra)['output_config']
            as Map)['effort'],
        'max',
      );
    });

    test('Claude 5 代默认在想但不给看:自动档补上 summarized,关不掉就压力度', () {
      final c5 = _llm(AgentApiFormat.anthropic, model: 'claude-opus-5-5');
      // 不带 display 时思考块是空串 —— 这正是「看不了思维链」
      expect(c5.thinkFields(ThinkLevel.auto), {
        'thinking': {'type': 'adaptive', 'display': 'summarized'},
      });
      // disabled 在这几个模型上是 400
      final off = c5.thinkFields(ThinkLevel.off);
      expect(off.containsKey('thinking'), isFalse);
      expect(off['output_config'], {'effort': 'low'});
      expect(c5.thinkNote(ThinkLevel.off), isNotNull, reason: '关不掉要说一声');
      // 4.6 ~ 4.8 默认不想:自动档不替它开
      expect(
        _llm(
          AgentApiFormat.anthropic,
          model: 'claude-opus-4-8',
        ).thinkFields(ThinkLevel.auto),
        isEmpty,
      );
    });

    test('Claude 的 max_tokens:老模型要大过预算,新模型给足思考的余量', () {
      int maxTokens(String model, ThinkLevel l) =>
          _llm(AgentApiFormat.anthropic, model: model).requestBody(
                LlmRequest(system: 's', messages: const [], think: l),
                stream: false,
              )['max_tokens']
              as int;
      expect(maxTokens('claude-sonnet-4-5', ThinkLevel.ultra), 4096 + 16384);
      expect(maxTokens('claude-opus-5-5', ThinkLevel.auto), 16000);
    });

    test('Responses:官方推理模型要摘要才看得到思考', () {
      expect(_responses('gpt-5.6').thinkFields(ThinkLevel.auto), {
        'reasoning': {'summary': 'auto'},
      });
      expect(_responses('o4-mini').thinkFields(ThinkLevel.auto), isNotEmpty);
      // 不推理的模型带了 reasoning 是 400
      for (final m in ['gpt-4o', 'gpt-4.1', 'gpt-5-chat-latest']) {
        expect(_responses(m).thinkFields(ThinkLevel.auto), isEmpty, reason: m);
      }
      expect(_responses('gpt-5').thinkFields(ThinkLevel.ultra), {
        'reasoning': {'effort': 'high', 'summary': 'auto'},
      });
    });

    test('OpenAI 兼容:认得出的服务商才发它家的思考开关', () {
      Map<String, dynamic> f(ThinkLevel l, String host, {bool stream = true}) {
        final body = _llm(AgentApiFormat.openai, base: 'https://$host/v1')
            .requestBody(
              LlmRequest(system: 's', messages: const [], think: l),
              stream: stream,
            );
        return {
          for (final e in body.entries)
            if (!const {'model', 'messages', 'stream'}.contains(e.key))
              e.key: e.value,
        };
      }

      // OpenAI 官方见到不认识的字段是 400
      expect(f(ThinkLevel.high, 'api.openai.com').keys, ['reasoning_effort']);
      // 通义
      expect(
        f(ThinkLevel.high, 'dashscope.aliyuncs.com')['enable_thinking'],
        isTrue,
      );
      expect(
        f(ThinkLevel.off, 'dashscope.aliyuncs.com')['enable_thinking'],
        isFalse,
      );
      expect(
        f(
          ThinkLevel.high,
          'dashscope.aliyuncs.com',
          stream: false,
        ).containsKey('enable_thinking'),
        isFalse,
        reason: '开源模型开着思考只能流式,非流式带 true 是 400',
      );
      // 智谱 / 豆包
      expect(f(ThinkLevel.high, 'open.bigmodel.cn')['thinking'], {
        'type': 'enabled',
      });
      expect(f(ThinkLevel.off, 'ark.cn-beijing.volces.com')['thinking'], {
        'type': 'disabled',
      });
      expect(f(ThinkLevel.auto, 'open.bigmodel.cn'), isEmpty);
      // 名字里带 z.ai 不算
      expect(f(ThinkLevel.high, 'xyz.ai').containsKey('thinking'), isFalse);
    });

    test('Gemini 的 OpenAI 兼容口:思考在 extra_body 里开', () {
      final f = _llm(
        AgentApiFormat.openai,
        model: 'gemini-3.7-flash',
        base: 'https://generativelanguage.googleapis.com/v1beta/openai',
      ).thinkFields(ThinkLevel.low);
      expect(f, {
        'extra_body': {
          'google': {
            'thinking_config': {
              'thinking_budget': 1024,
              'include_thoughts': true,
            },
          },
        },
      });
      expect(f.containsKey('reasoning_effort'), isFalse, reason: '两个只能给一个');
    });
  });

  group('Responses 报文', () {
    test('打 /responses,带 instructions 与摘要,流里正文和思考分开', () async {
      late Uri uri;
      late Map<String, dynamic> sent;
      final c = _client(
        [
          'event: response.reasoning_summary_text.delta\n'
              'data: {"type":"response.reasoning_summary_text.delta","delta":"想"}\n\n',
          'event: response.output_text.delta\n'
              'data: {"type":"response.output_text.delta","delta":"好的"}\n\n',
        ].join(),
        onRequest: (req, b) {
          uri = req.url;
          sent = jsonDecode(b) as Map<String, dynamic>;
        },
      );
      final r = await _run(c, _responses('gpt-5.6'));

      expect(uri.toString(), 'http://api.test/v1/responses');
      expect(sent['instructions'], 'sys');
      expect(sent['input'], [
        {'role': 'user', 'content': '画一张'},
      ]);
      expect(sent['reasoning'], {'summary': 'auto'});
      expect(sent['store'], isFalse);
      expect(r.last.text, '好的');
      expect(r.last.reasoning, '想');
    });

    test('没认证不给摘要 → 去掉摘要重发一次,照常出词', () async {
      final sent = <Map<String, dynamic>>[];
      final c = MockClient.streaming((req, bodyStream) async {
        sent.add(
          jsonDecode(utf8.decode(await bodyStream.toBytes()))
              as Map<String, dynamic>,
        );
        if (sent.length == 1) {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'error': {
                    'message':
                        'Your organization must be verified to generate reasoning summaries.',
                  },
                }),
              ),
            ),
            400,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              _sse(['{"type":"response.output_text.delta","delta":"好的"}']),
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final r = await _run(c, _responses('o4-mini'));

      expect(sent, hasLength(2));
      expect(
        (sent.last['reasoning'] as Map?)?.containsKey('summary'),
        isNot(true),
      );
      expect(r.last.text, '好的');
    });

    test('别的 400 不重发:模型名写错不能被掩盖成白跑一趟', () async {
      var calls = 0;
      final c = MockClient.streaming((req, _) async {
        calls++;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'error': {'message': 'model not found'},
              }),
            ),
          ),
          400,
          headers: {'content-type': 'application/json'},
        );
      });
      await expectLater(
        _run(c, _responses('gpt-5')),
        throwsA(isA<AgentFailure>()),
      );
      expect(calls, 1);
    });

    test('流中途失败:把原因报出来', () async {
      final c = _client(
        _sse([
          '{"type":"response.failed","response":{"error":{"message":"上游过载"}}}',
        ]),
      );
      await expectLater(
        _run(c, _responses()),
        throwsA(
          isA<AgentFailure>().having(
            (e) => e.message,
            'message',
            contains('上游过载'),
          ),
        ),
      );
    });

    test('接口存档:开关只在 OpenAI 下落盘;iOS 旧存档的 responses 格式读成开关', () {
      final e = _ep(AgentApiFormat.openai, responses: true);
      expect(e.toJson()['format'], 'openai', reason: '老版本读到的还是能用的 OpenAI');
      expect(CustomEndpoint.fromJson(e.toJson())!.responses, isTrue);
      expect(
        _ep(AgentApiFormat.google, responses: true).toJson(),
        isNot(contains('responses')),
      );
      final legacy = CustomEndpoint.fromJson(const {
        'id': 'y',
        'format': 'responses',
        'models': ['gpt-5'],
      })!;
      expect(legacy.format, AgentApiFormat.openai);
      expect(legacy.responses, isTrue);
      expect(legacy.chatUri.path, '/v1/responses');
      expect(
        llmProviderFor(legacy).runtimeType.toString(),
        'ResponsesProvider',
      );
      // 贴了整条 Responses 地址的切掉路径
      expect(
        normalizeEndpointBase(
          'https://api.openai.com/v1/responses',
          AgentApiFormat.openai,
        ),
        'https://api.openai.com/v1',
      );
    });
  });

  group('请求里的思考', () {
    test('Gemini 自动档:会思考的模型请求里带 includeThoughts,思考段不进原文', () async {
      late Map<String, dynamic> sent;
      final c = _client(
        _sse([
          '{"candidates":[{"content":{"parts":[{"text":"想","thought":true},{"text":"好的"}]}}]}',
        ]),
        onRequest: (_, b) => sent = jsonDecode(b) as Map<String, dynamic>,
      );
      final r = await _run(
        c,
        _llm(AgentApiFormat.google, model: 'gemini-2.5-flash'),
      );
      expect(
        ((sent['generationConfig'] as Map)['thinkingConfig']
            as Map)['includeThoughts'],
        isTrue,
      );
      expect(r.last.text, '好的', reason: '思考段不进原文,不然会被当正文解析');
      expect(r.last.reasoning, '想');
    });

    test('非流式也把原生思考交出来', () async {
      final c = _client(
        jsonEncode({
          'content': [
            {'type': 'thinking', 'thinking': '想'},
            {'type': 'text', 'text': '好的'},
          ],
        }),
        contentType: 'application/json',
      );
      final r = await _run(c, _llm(AgentApiFormat.anthropic), stream: false);
      expect(r.single.text, '好的');
      expect(r.single.reasoning, '想');
    });
  });

  group('思考过程', () {
    test('跟着 AI 消息落盘,copyWith 不丢;老存档读成空', () {
      const m = AssistantMsg(
        id: 'a',
        role: MsgRole.ai,
        text: '好的',
        at: 1,
        reasoning: '先想想',
      );
      final back = AssistantMsg.fromJson(m.toJson());
      expect(back.reasoning, '先想想');
      expect(back.copyWith(imageIds: const ['g1']).reasoning, '先想想');
      expect(
        AssistantMsg.fromJson(const {
          'id': 'b',
          'role': 'ai',
          'text': 'x',
        }).reasoning,
        '',
      );
      expect(
        const AssistantMsg(
          id: 'c',
          role: MsgRole.ai,
          text: 'x',
          at: 1,
        ).toJson().containsKey('reasoning'),
        isFalse,
      );
    });

    test('一轮跑完:每一跳的思考(原生的和 <think> 里的)都带进结果', () async {
      final runtime = LocalAgentRuntime(
        provider: _ScriptedLlm([
          (
            text:
                '```tool_call\n{"name":"fake_lookup","arguments":{"q":"x"}}\n```',
            reasoning: '先查一下',
          ),
          (text: '<think>定下来了</think>画好了', reasoning: ''),
        ]),
        tools: const [_FakeTool()],
      );
      final events = await runtime
          .run(
            const AgentTurnRequest(
              userText: '画一张',
              imageModel: 'nai_v45_full',
              customRules: [PresetRule(name: 'role', content: '你是画师')],
              stream: false,
              retries: 0,
            ),
          )
          .toList();
      final done = events.whereType<AgentDone>().single;
      expect(done.result.replyText, '画好了');
      expect(done.result.reasoning, '先查一下\n\n定下来了');
    });
  });

  group('选择键', () {
    test('iOS 版早先用冒号分隔接口 id 和模型,照样认', () {
      expect(customEndpointIdOf('custom:ep1_0:qwen3:8b'), 'ep1_0');
      expect(customModelOf('custom:ep1_0:qwen3:8b'), 'qwen3:8b');
      // 现在的写法:斜杠分隔,模型名里的冒号斜杠原样留着
      expect(customEndpointIdOf(customModelKey('ep1', 'a/b:c')), 'ep1');
      expect(customModelOf(customModelKey('ep1', 'a/b:c')), 'a/b:c');
      expect(customModelOf('custom:ep1'), isNull);
      const e = CustomEndpoint(
        id: 'ep1',
        name: '',
        format: AgentApiFormat.openai,
        baseUrl: '',
        apiKey: 'k',
        model: 'a',
        models: ['a', 'b'],
      );
      expect(resolveCustomChoice(e, 'custom:ep1:b')!.model, 'b');
      expect(resolveCustomChoice(e, 'custom:ep1:gone')!.model, 'a');
    });
  });
}
