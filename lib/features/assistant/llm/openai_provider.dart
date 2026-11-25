import '../../../l10n/l10n.dart';
import '../assistant_settings.dart' show ThinkLevel;
import 'http_provider.dart';
import 'llm_provider.dart';

/// 会思考的 Gemini(2.5 起)。只有这些认 `include_thoughts`。
final _geminiThinks = RegExp(r'gemini-(?:2\.5|[3-9])', caseSensitive: false);

/// Gemini 兼容口、通义的思考预算(token)。
int _thinkBudget(ThinkLevel l) => switch (l) {
  ThinkLevel.off => 0,
  ThinkLevel.low => 1024,
  ThinkLevel.high => 16384,
  ThinkLevel.ultra => 24576,
  _ => 8192,
};

/// [host] 是 [domain] 本身或它的子域。
bool _hostIs(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// OpenAI 兼容的一条消息(非流式的 `message` / 流式的 `delta`)→ 正文与思考。
///
/// 「OpenAI 兼容」只兼容到正文为止,思考各家各写各的:
///   · `reasoning_content`:DeepSeek、通义、智谱、豆包、Kimi、硅基流动、LM Studio、老版 vLLM;
///     多数中转把 Claude / Gemini 的思考也转成这个
///   · `reasoning`:OpenRouter、Ollama、新版 vLLM
///   · `reasoning_details[]`:OpenRouter 的另一份,有的模型 `reasoning` 空着、
///     思考只在这里(原文 `text` 或摘要 `summary`;加密的那种没字可看)
///   · `content` 是分段数组、思考段 `type: thinking`:Mistral 的推理模型
/// 写在正文里的 `<think>` 那一派(MiniMax、部分本地模型)不在这里,留在正文里由
/// `reply_parser` 切。
LlmText openAiMessage(Map m) {
  final text = StringBuffer();
  final think = StringBuffer();
  final c = m['content'];
  if (c is String) {
    text.write(c);
  } else if (c is List) {
    for (final p in c) {
      if (p is! Map) continue;
      if (p['type'] == 'thinking') {
        think.write(_flatText(p['thinking']));
      } else if (p['text'] is String) {
        text.write(p['text']);
      }
    }
  }
  final r = m['reasoning_content'] ?? m['reasoning'];
  if (r is String && r.isNotEmpty) {
    think.write(r);
  } else if (m['reasoning_details'] case final List details) {
    for (final d in details) {
      if (d is! Map) continue;
      final t = d['text'] ?? d['summary'];
      if (t is String) think.write(t);
    }
  }
  return (text: text.toString(), reasoning: think.toString());
}

/// 字符串原样;分段数组(`[{type: text, text}]`)拼起来。
String _flatText(Object? v) => switch (v) {
  final String s => s,
  final List l => [
    for (final p in l)
      if (p is String)
        p
      else if (p is Map && p['text'] is String)
        p['text'] as String,
  ].join(),
  _ => '',
};

/// OpenAI 兼容(`/chat/completions`,`Authorization: Bearer`)。绝大多数中转、本地推理都是这个。
class OpenAiProvider extends HttpLlmProvider {
  OpenAiProvider(super.endpoint);

  @override
  Map<String, String> get authHeaders => {'Authorization': 'Bearer $apiKey'};

  @override
  Map<String, dynamic> requestBody(LlmRequest r, {required bool stream}) => {
    'model': endpoint.model,
    'messages': [
      {'role': 'system', 'content': r.system},
      for (final m in r.messages)
        {
          'role': m.role,
          'content': m.images.isEmpty
              ? m.content
              : [
                  for (final i in m.images)
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:${i.mime};base64,${i.data}'},
                    },
                  if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
                ],
        },
    ],
    if (stream) 'stream': true,
    ..._think(r.think, stream: stream),
  };

  @override
  Map<String, dynamic> thinkFields(ThinkLevel level) =>
      _think(level, stream: true);

  /// `reasoning_effort` 两头都封顶:没有「关」,minimal 是最低;没有「超高」,high 是最高。
  ///
  /// 「OpenAI 兼容」只兼容到正文为止,几家认得出地址的服务商另有自己的思考开关,
  /// 只对它们发(OpenAI 官方见到不认识的字段是 400)。
  /// [stream]:通义的开源模型开着思考时只能流式,非流式带 `enable_thinking: true` 直接 400。
  Map<String, dynamic> _think(ThinkLevel level, {required bool stream}) {
    final host = endpoint.chatUri.host.toLowerCase();
    // Gemini 的 OpenAI 兼容口:思考要在 extra_body 里另开,开了才会把思考
    // 包成 `<thought>` 写进正文;`reasoning_effort` 和预算两个只能给一个
    if (_hostIs(host, 'generativelanguage.googleapis.com')) {
      if (level == ThinkLevel.auto && !_geminiThinks.hasMatch(endpoint.model)) {
        return const {};
      }
      return {
        'extra_body': {
          'google': {
            'thinking_config': {
              if (level != ThinkLevel.auto)
                'thinking_budget': _thinkBudget(level),
              if (level != ThinkLevel.off) 'include_thoughts': true,
            },
          },
        },
      };
    }
    if (level == ThinkLevel.auto) return const {};
    final on = level != ThinkLevel.off;
    return {
      'reasoning_effort': switch (level) {
        ThinkLevel.off => 'minimal',
        ThinkLevel.low => 'low',
        ThinkLevel.high || ThinkLevel.ultra => 'high',
        _ => 'medium',
      },
      // 通义:思考靠 enable_thinking 开关,不认 reasoning_effort
      if (host.startsWith('dashscope') && _hostIs(host, 'aliyuncs.com'))
        if (!on)
          'enable_thinking': false
        else if (stream) ...{
          'enable_thinking': true,
          'thinking_budget': _thinkBudget(level),
        },
      // 智谱 / 豆包:thinking.type 开关
      if (_hostIs(host, 'bigmodel.cn') ||
          _hostIs(host, 'z.ai') ||
          _hostIs(host, 'volces.com'))
        'thinking': {'type': on ? 'enabled' : 'disabled'},
    };
  }

  @override
  String? thinkNote(ThinkLevel level) => switch (level) {
    ThinkLevel.off => l10nNow.thinkNoOffFormat,
    ThinkLevel.ultra => l10nNow.thinkNoUltraFormat,
    _ => null,
  };

  /// `delta` 的正文与思考,见 [openAiMessage]。老式补全接口没有 delta,只有 text。
  @override
  LlmText parseDelta(Object? frame) {
    const none = (text: '', reasoning: '');
    final first = _firstChoice(frame);
    if (first == null) return none;
    final d = first['delta'];
    if (d is! Map) {
      return (
        text: first['text'] is String ? first['text'] as String : '',
        reasoning: '',
      );
    }
    return openAiMessage(d);
  }

  /// `choices[0].message` 的正文,老式补全接口是 `choices[0].text`。
  @override
  String parseResponse(Object? body) {
    final first = _firstChoice(body);
    if (first == null) return '';
    final msg = first['message'];
    if (msg is Map) return openAiMessage(msg).text;
    return first['text']?.toString() ?? '';
  }

  @override
  String parseResponseReasoning(Object? body) {
    final msg = _firstChoice(body)?['message'];
    return msg is Map ? openAiMessage(msg).reasoning : '';
  }

  static Map? _firstChoice(Object? body) {
    if (body is! Map) return null;
    final choices = body['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    return first is Map ? first : null;
  }

  /// `{"data":[{"id":"gpt-4o"}]}`
  @override
  List<String> parseModels(Object? body) =>
      body is Map ? modelIdsOf(body['data']) : const [];
}
