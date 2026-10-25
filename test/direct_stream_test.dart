// 自填接口那条的流式:三家的增量帧解析、流到一半时正文/思考怎么切、
// 以及中转不认流式时的回落。
//
// 这几处坏掉的表现都很像「模型自己慢」或「模型没回」:认错 delta 字段 = 一路空白
// 最后整段蹦出来;切错正文 = 把 <Think> 或者围栏里的 JSON 摊给用户看。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plana_app/core/net/agent_stream.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/direct_agent.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';

CustomEndpoint _ep(AgentApiFormat f) => CustomEndpoint(
  id: 'e1',
  name: 'test',
  format: f,
  baseUrl: 'http://api.test/v1',
  apiKey: 'k',
  model: 'm1',
);

/// 一段 SSE 响应体。
String _sse(List<String> frames) => frames.map((f) => 'data: $f\n\n').join();

MockClient _streamingClient(
  String body, {
  String contentType = 'text/event-stream',
  int status = 200,
  void Function(http.BaseRequest req, String body)? onRequest,
}) => MockClient.streaming((req, bodyStream) async {
  onRequest?.call(req, utf8.decode(await bodyStream.toBytes()));
  return http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    status,
    headers: {'content-type': contentType},
  );
});

Future<({String raw, List<AgentDelta> deltas, String reasoning})> _run(
  http.Client c,
  CustomEndpoint e, {
  bool stream = true,
}) async {
  final out = StringBuffer();
  final reasoning = StringBuffer();
  final deltas = await directModelStream(
    c,
    e,
    system: 'sys',
    msgs: const [(role: 'user', content: '画一张', image: null)],
    think: ThinkLevel.auto,
    timeout: const Duration(seconds: 5),
    out: out,
    reasoning: reasoning,
    stream: stream,
  ).toList();
  return (raw: out.toString(), deltas: deltas, reasoning: reasoning.toString());
}

void main() {
  group('directDelta', () {
    test('OpenAI:content 与两种 reasoning 字段', () {
      expect(
        directDelta(AgentApiFormat.openai, {
          'choices': [
            {
              'delta': {'content': '好的'},
            },
          ],
        }),
        (text: '好的', reasoning: ''),
      );
      // DeepSeek 那套
      expect(
        directDelta(AgentApiFormat.openai, {
          'choices': [
            {
              'delta': {'reasoning_content': '先想想'},
            },
          ],
        }),
        (text: '', reasoning: '先想想'),
      );
      // OpenRouter 那套
      expect(
        directDelta(AgentApiFormat.openai, {
          'choices': [
            {
              'delta': {'reasoning': '先想想'},
            },
          ],
        }),
        (text: '', reasoning: '先想想'),
      );
      // 收尾那帧只有 finish_reason,不带字
      expect(
        directDelta(AgentApiFormat.openai, {
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
        }),
        (text: '', reasoning: ''),
      );
    });

    test('Gemini:thought 为真的那几段算思考', () {
      expect(
        directDelta(AgentApiFormat.google, {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '先想想', 'thought': true},
                  {'text': '好的'},
                ],
              },
            },
          ],
        }),
        (text: '好的', reasoning: '先想想'),
      );
    });

    test('Claude:text_delta / thinking_delta,别的帧不带字', () {
      expect(
        directDelta(AgentApiFormat.anthropic, {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': '好的'},
        }),
        (text: '好的', reasoning: ''),
      );
      expect(
        directDelta(AgentApiFormat.anthropic, {
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': '先想想'},
        }),
        (text: '', reasoning: '先想想'),
      );
      // message_delta 也带 delta,但里面是停止原因
      expect(
        directDelta(AgentApiFormat.anthropic, {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
        }),
        (text: '', reasoning: ''),
      );
    });

    test('不认识的帧一律当没字,不抛', () {
      for (final f in AgentApiFormat.values) {
        expect(directDelta(f, null), (text: '', reasoning: ''));
        expect(directDelta(f, 'oops'), (text: '', reasoning: ''));
        expect(directDelta(f, const <String, Object?>{}), (
          text: '',
          reasoning: '',
        ));
      }
    });
  });

  group('directDelta:各家的思考字段', () {
    test('OpenRouter:reasoning 空着时从 reasoning_details 取', () {
      expect(
        directDelta(AgentApiFormat.openai, {
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
        directDelta(AgentApiFormat.openai, {
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
        directDelta(AgentApiFormat.openai, {
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
      expect(
        directDelta(AgentApiFormat.responses, {
          'type': 'response.output_text.delta',
          'delta': '好的',
        }),
        (text: '好的', reasoning: ''),
      );
      expect(
        directDelta(AgentApiFormat.responses, {
          'type': 'response.reasoning_summary_text.delta',
          'delta': '想',
        }),
        (text: '', reasoning: '想'),
      );
      expect(
        directDelta(AgentApiFormat.responses, {
          'type': 'response.reasoning_text.delta',
          'delta': '想',
        }),
        (text: '', reasoning: '想'),
      );
      // 第二段摘要开头空一行;第一段不空
      expect(
        directDelta(AgentApiFormat.responses, {
          'type': 'response.reasoning_summary_part.added',
          'summary_index': 1,
        }).reasoning,
        '\n\n',
      );
      expect(
        directDelta(AgentApiFormat.responses, {
          'type': 'response.reasoning_summary_part.added',
          'summary_index': 0,
        }).reasoning,
        '',
      );
      expect(
        directDelta(AgentApiFormat.responses, {'type': 'response.completed'}),
        (text: '', reasoning: ''),
      );
    });
  });

  group('directStreamView', () {
    test('收完的 <Think> 划到思考,正文接着往下', () {
      final v = directStreamView('<Think>先想想</Think>好的,画一张');
      expect(v.body, '好的,画一张');
      expect(v.think, '先想想');
    });

    test('还没收尾的 <Think>:后面全算思考', () {
      final v = directStreamView('<Think>先想想,这个词');
      expect(v.body, isEmpty);
      expect(v.think, '先想想,这个词');
    });

    test('围栏一开始正文就到此为止', () {
      final v = directStreamView('我查一下画师\n```tool_call\n{"name": "sear');
      expect(v.body, '我查一下画师');
      expect(v.think, isEmpty);
      final d = directStreamView('画好了\n```nai_draw\n{"positive": "1girl');
      expect(d.body, '画好了');
    });

    test('普通代码块照留 —— 回复里列 tag 会用到', () {
      const raw = '给你:\n```\n1girl, blue eyes\n```';
      expect(directStreamView(raw).body, raw);
    });

    test('收到一半的标签和围栏头不露出来', () {
      expect(directStreamView('好的 <Thi').body, '好的');
      expect(directStreamView('好的\n```nai_dr').body, '好的');
      // 光秃秃的反引号留着:多半是代码块/行内代码的收尾,切了反而拆了好好的块
      expect(directStreamView('给你 `1girl`').body, '给你 `1girl`');
    });

    test('多段 <Think> 合到一起', () {
      final v = directStreamView('<Think>一</Think>甲<Think>二</Think>乙');
      expect(v.body, '甲乙');
      expect(v.think, '一\n二');
    });
  });

  group('directModelStream', () {
    test('OpenAI:边收边吐,原文攒齐,最后一帧是全量', () async {
      late String sent;
      final c = _streamingClient(
        _sse([
          '{"choices":[{"delta":{"reasoning_content":"想"}}]}',
          '{"choices":[{"delta":{"content":"好的"}}]}',
          '{"choices":[{"delta":{"content":",画一张"}}]}',
          '[DONE]',
        ]),
        onRequest: (_, b) => sent = b,
      );
      final r = await _run(c, _ep(AgentApiFormat.openai));

      expect(jsonDecode(sent)['stream'], isTrue, reason: '得真的开流');
      expect(r.raw, '好的,画一张', reason: 'reasoning 不进原文,不然会被当正文解析');
      expect(r.deltas, isNotEmpty);
      expect(r.deltas.last.text, '好的,画一张');
      expect(r.deltas.last.reasoning, '想');
    });

    test('Claude:换成 content_block_delta,地址不变', () async {
      late Uri uri;
      final c = _streamingClient(
        _sse([
          '{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"想"}}',
          '{"type":"content_block_delta","delta":{"type":"text_delta","text":"好的"}}',
        ]),
        onRequest: (req, _) => uri = req.url,
      );
      final r = await _run(c, _ep(AgentApiFormat.anthropic));

      expect(uri.toString(), 'http://api.test/v1/messages');
      expect(r.raw, '好的');
      expect(r.deltas.last.reasoning, '想');
    });

    test('Gemini:换成 streamGenerateContent 并带 alt=sse', () async {
      late Uri uri;
      final c = _streamingClient(
        _sse(['{"candidates":[{"content":{"parts":[{"text":"好的"}]}}]}']),
        onRequest: (req, _) => uri = req.url,
      );
      final r = await _run(c, _ep(AgentApiFormat.google));

      expect(uri.path, '/v1/models/m1:streamGenerateContent');
      expect(uri.queryParameters['alt'], 'sse');
      expect(r.raw, '好的');
    });

    test('自定义请求头随请求发出,同名覆盖默认头', () async {
      late Map<String, String> sent;
      final c = _streamingClient(
        _sse(['{"choices":[{"delta":{"content":"好的"}}]}']),
        onRequest: (req, _) => sent = req.headers,
      );
      await _run(
        c,
        _ep(
          AgentApiFormat.openai,
        ).copyWith(headers: {'X-Title': 'Plana', 'authorization': 'Token t'}),
      );

      expect(sent['X-Title'], 'Plana');
      expect(sent['Authorization'], 'Token t');
      expect(sent['Content-Type'], 'application/json');
    });

    test('中转不认流式:整段收完照样出结果', () async {
      final c = _streamingClient(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '好的,画一张'},
            },
          ],
        }),
        contentType: 'application/json',
      );
      final r = await _run(c, _ep(AgentApiFormat.openai));

      expect(r.raw, '好的,画一张');
      expect(r.deltas.single.text, '好的,画一张');
    });

    test('中转把 SSE 写成 json 类型:照样按帧收', () async {
      final c = _streamingClient(
        _sse([
          '{"choices":[{"delta":{"content":"好的"}}]}',
          '{"choices":[{"delta":{"content":",画一张"}}]}',
        ]),
        contentType: 'application/json',
      );
      final r = await _run(c, _ep(AgentApiFormat.openai));
      expect(r.raw, '好的,画一张');
    });

    test('设置里关掉:不开流、一帧不推,打的还是原来那个地址', () async {
      late Uri uri;
      late String sent;
      final c = _streamingClient(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '好的'},
            },
          ],
        }),
        contentType: 'application/json',
        onRequest: (req, b) {
          uri = req.url;
          sent = b;
        },
      );
      final r = await _run(c, _ep(AgentApiFormat.openai), stream: false);

      expect(r.deltas, isEmpty, reason: '关着就该老老实实转圈到出结果');
      expect(r.raw, '好的');
      expect((jsonDecode(sent) as Map).containsKey('stream'), isFalse);
      expect(uri.toString(), 'http://api.test/v1/chat/completions');
    });

    test('关掉时 Gemini 也回到 generateContent', () async {
      late Uri uri;
      final c = _streamingClient(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '好的'},
                ],
              },
            },
          ],
        }),
        contentType: 'application/json',
        onRequest: (req, _) => uri = req.url,
      );
      await _run(c, _ep(AgentApiFormat.google), stream: false);
      expect(uri.path, '/v1/models/m1:generateContent');
      expect(uri.queryParameters['alt'], isNull);
    });

    test('HTTP 错误体:把上游的话原样报出来', () async {
      final c = _streamingClient(
        jsonEncode({
          'error': {'message': '额度不足'},
        }),
        contentType: 'application/json',
        status: 429,
      );
      await expectLater(
        _run(c, _ep(AgentApiFormat.openai)),
        throwsA(
          isA<BackendException>().having((e) => e.message, 'message', '额度不足'),
        ),
      );
    });

    test('Claude 把报错发在流中间:同样要抛出来', () async {
      final c = _streamingClient(
        _sse([
          '{"type":"content_block_delta","delta":{"type":"text_delta","text":"好"}}',
          '{"type":"error","error":{"message":"上游过载"}}',
        ]),
      );
      await expectLater(
        _run(c, _ep(AgentApiFormat.anthropic)),
        throwsA(
          isA<BackendException>().having((e) => e.message, 'message', '上游过载'),
        ),
      );
    });

    test('Responses:打 /responses,带 instructions 与摘要,流里正文和思考分开', () async {
      late Uri uri;
      late Map<String, dynamic> sent;
      final c = _streamingClient(
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
      final r = await _run(
        c,
        _ep(AgentApiFormat.responses).withModel('gpt-5.6'),
      );

      expect(uri.toString(), 'http://api.test/v1/responses');
      expect(sent['instructions'], 'sys');
      expect(sent['input'], [
        {'role': 'user', 'content': '画一张'},
      ]);
      expect(sent['reasoning'], {'summary': 'auto'});
      expect(sent['store'], isFalse);
      expect(r.raw, '好的');
      expect(r.reasoning, '想');
      expect(r.deltas.last.reasoning, '想');
    });

    test('Responses:没认证不给摘要 → 去掉摘要重发一次,照常出词', () async {
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
      final r = await _run(
        c,
        _ep(AgentApiFormat.responses).withModel('o4-mini'),
      );

      expect(sent, hasLength(2));
      expect(
        (sent.last['reasoning'] as Map?)?.containsKey('summary'),
        isNot(true),
      );
      expect(r.raw, '好的');
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
        _run(c, _ep(AgentApiFormat.responses).withModel('gpt-5')),
        throwsA(isA<BackendException>()),
      );
      expect(calls, 1);
    });

    test('Responses 流中途失败:把原因报出来', () async {
      final c = _streamingClient(
        _sse([
          '{"type":"response.failed","response":{"error":{"message":"上游过载"}}}',
        ]),
      );
      await expectLater(
        _run(c, _ep(AgentApiFormat.responses)),
        throwsA(
          isA<BackendException>().having((e) => e.message, 'message', '上游过载'),
        ),
      );
    });

    test('Gemini 自动档:会思考的模型请求里带 includeThoughts', () async {
      late Map<String, dynamic> sent;
      final c = _streamingClient(
        _sse([
          '{"candidates":[{"content":{"parts":[{"text":"想","thought":true},{"text":"好的"}]}}]}',
        ]),
        onRequest: (_, b) => sent = jsonDecode(b) as Map<String, dynamic>,
      );
      final r = await _run(
        c,
        _ep(AgentApiFormat.google).withModel('gemini-3.7-flash'),
      );
      expect(
        ((sent['generationConfig'] as Map)['thinkingConfig']
            as Map)['includeThoughts'],
        isTrue,
      );
      expect(r.raw, '好的', reason: '思考段不进原文,不然会被当正文解析');
      expect(r.reasoning, '想');
    });

    test('非流式也把原生思考交出来', () async {
      final c = _streamingClient(
        jsonEncode({
          'content': [
            {'type': 'thinking', 'thinking': '想'},
            {'type': 'text', 'text': '好的'},
          ],
        }),
        contentType: 'application/json',
      );
      final r = await _run(c, _ep(AgentApiFormat.anthropic), stream: false);
      expect(r.raw, '好的');
      expect(r.reasoning, '想');
    });

    test('围栏在流里:正文只到围栏前,原文一个字不少', () async {
      final c = _streamingClient(
        _sse([
          '{"choices":[{"delta":{"content":"我查一下\\n"}}]}',
          '{"choices":[{"delta":{"content":"```tool_call\\n{\\"name\\":\\"search_artist\\"}\\n```"}}]}',
        ]),
      );
      final r = await _run(c, _ep(AgentApiFormat.openai));

      expect(r.deltas.last.text, '我查一下');
      expect(
        r.raw,
        '我查一下\n```tool_call\n{"name":"search_artist"}\n```',
        reason: '解析用的是原文,围栏得原样留着',
      );
      expect(parseToolCalls(r.raw).single.name, 'search_artist');
    });
  });

  group('streamDirectPrompt', () {
    test('一轮跑完:每一跳的思考(原生的和 <think> 里的)都带进结果', () async {
      var call = 0;
      final mock = MockClient((req) async {
        call++;
        final body = call == 1
            ? {
                'choices': [
                  {
                    'message': {
                      'reasoning_content': '先查一下',
                      'content':
                          '```tool_call\n{"name":"lookup_tag","arguments":{"q":"x"}}\n```',
                    },
                  },
                ],
              }
            : {
                'choices': [
                  {
                    'message': {'content': '<think>定下来了</think>画好了'},
                  },
                ],
              };
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final events = await http.runWithClient(
        () => streamDirectPrompt(
          endpoint: _ep(AgentApiFormat.openai),
          backendBase: '',
          sessionId: '',
          userRequest: '画一张',
          rules: const [PresetRule(name: 'role', content: '你是画师')],
          libraryScope: 'none',
          stream: false,
        ).toList(),
        () => mock,
      );
      final done = events.whereType<AgentDone>().single;
      expect(done.result.replyText, '画好了');
      expect(done.result.reasoning, '先查一下\n\n定下来了');
    });
  });
}
