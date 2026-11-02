import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/direct_agent.dart';

void main() {
  CustomEndpoint ep(AgentApiFormat f) => CustomEndpoint(
    id: 'e',
    name: '',
    format: f,
    baseUrl: '',
    apiKey: 'k',
    model: 'claude-opus-5-5',
  );
  const mark = {'type': 'ephemeral'};
  DirectMsg text(String role, String content) =>
      (role: role, content: content, image: null);
  Map<String, dynamic> body(
    List<DirectMsg> msgs, {
    String system = 'RULES',
    AgentApiFormat f = AgentApiFormat.anthropic,
  }) => directRequest(
    ep(f),
    system: system,
    msgs: msgs,
    think: ThinkLevel.auto,
  ).$2;

  group('Claude 缓存标记', () {
    test('系统提示整段一个缓存点', () {
      expect(body([text('user', '画个芙兰')])['system'], [
        {'type': 'text', 'text': 'RULES', 'cache_control': mark},
      ]);
    });

    test('系统提示是空的就不发 system,不塞空块', () {
      expect(
        body([text('user', '画个芙兰')], system: ''),
        isNot(contains('system')),
      );
    });

    test('每轮第一跳:历史末尾和本轮那条各一个,更早的原样是字符串', () {
      final m =
          body([
                text('user', '第一句'),
                text('assistant', '第一答'),
                text('user', '第二句'),
                text('assistant', '第二答'),
                text('user', '本轮'),
              ])['messages']
              as List;
      expect([for (final x in m.take(3)) x['content']], ['第一句', '第一答', '第二句']);
      expect(m[3]['content'], [
        {'type': 'text', 'text': '第二答', 'cache_control': mark},
      ]);
      expect(m[4]['content'], [
        {'type': 'text', 'text': '本轮', 'cache_control': mark},
      ]);
    });

    test('查资料回来那一跳:标在刚追加的两条上,一共不超过四个点', () {
      final b = body([
        text('user', '上一句'),
        text('assistant', '上一答'),
        text('user', '本轮'),
        text('assistant', '```tool_call\n{}\n```'),
        text('user', '[tool_result 共 1 条]'),
      ]);
      final raw = jsonEncode(b);
      expect('cache_control'.allMatches(raw).length, 3);
      final m = b['messages'] as List;
      expect(m[2]['content'], '本轮', reason: '上一跳写过的点,这一跳从它读');
      expect((m[3]['content'] as List).single['cache_control'], mark);
      expect((m[4]['content'] as List).single['cache_control'], mark);
    });

    test('带图:标在最后一块,图在前', () {
      const img = (mime: 'image/png', data: 'QUJD');
      final m =
          body([(role: 'user', content: '', image: img)])['messages'] as List;
      expect(m.single['content'], [
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/png',
            'data': 'QUJD',
          },
          'cache_control': mark,
        },
      ]);
    });

    test('只有一条空消息:挂不了标记,原样发,不出空 text 块', () {
      final raw = jsonEncode(body([text('user', '')]));
      expect(raw, isNot(contains('"text":""')));
      expect((body([text('user', '')])['messages'] as List).single, {
        'role': 'user',
        'content': '',
      });
    });

    test('其他格式不加标记(它们按前缀自动缓存)', () {
      for (final f in AgentApiFormat.values) {
        if (f == AgentApiFormat.anthropic) continue;
        final raw = jsonEncode(
          body([
            text('user', 'a'),
            text('assistant', 'b'),
            text('user', 'c'),
          ], f: f),
        );
        expect(raw, isNot(contains('cache_control')), reason: f.name);
      }
    });
  });
}
