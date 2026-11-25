import '../../../l10n/l10n.dart';
import '../assistant_settings.dart' show ThinkLevel;
import 'http_provider.dart';
import 'llm_provider.dart';

/// 有推理能力的 OpenAI 模型:只有这些认 `reasoning`,别的(4o、4.1)带了就 400。
/// `gpt-5-chat` 那几个名字里带 5 却是不推理的聊天模型。
final _openaiReasons = RegExp(
  r'(?:^|/)(?:o\d|gpt-5(?!.*chat)|gpt-oss|codex)',
  caseSensitive: false,
);

/// OpenAI Responses(`/responses`,鉴权同 OpenAI)。挂在 OpenAI 格式下的一个开关
/// (见 `CustomEndpoint.responses`)。
///
/// OpenAI 官方的推理模型(o 系、GPT-5)**只在这条接口上回思考摘要** ——
/// `/chat/completions` 上它们想归想,一个字都不给你看。
class ResponsesProvider extends HttpLlmProvider {
  ResponsesProvider(super.endpoint);

  @override
  Map<String, String> get authHeaders => {'Authorization': 'Bearer $apiKey'};

  @override
  Map<String, dynamic> requestBody(LlmRequest r, {required bool stream}) => {
    'model': endpoint.model,
    if (r.system.isNotEmpty) 'instructions': r.system,
    'input': [
      for (final m in r.messages)
        {
          'role': m.role,
          'content': m.images.isEmpty
              ? m.content
              : [
                  for (final i in m.images)
                    {
                      'type': 'input_image',
                      'image_url': 'data:${i.mime};base64,${i.data}',
                    },
                  if (m.content.isNotEmpty)
                    {'type': 'input_text', 'text': m.content},
                ],
        },
    ],
    if (stream) 'stream': true,
    // 历史每轮都是 app 自己带着发的,用不着服务端再替你存一份对话
    'store': false,
    ...thinkFields(r.think),
  };

  /// 摘要是官方推理模型唯一能看的思考,不要就一个字都没有。
  /// 没认证的组织要了会被拒,那时去掉摘要重发(见 [retryBody])。
  @override
  Map<String, dynamic> thinkFields(ThinkLevel level) => switch (level) {
    ThinkLevel.auto =>
      _openaiReasons.hasMatch(endpoint.model)
          ? {
              'reasoning': {'summary': 'auto'},
            }
          : const {},
    ThinkLevel.off => {
      'reasoning': {'effort': 'minimal'},
    },
    _ => {
      'reasoning': {
        'effort': switch (level) {
          ThinkLevel.low => 'low',
          ThinkLevel.medium => 'medium',
          _ => 'high',
        },
        'summary': 'auto',
      },
    },
  };

  @override
  String? thinkNote(ThinkLevel level) => switch (level) {
    ThinkLevel.off => l10nNow.thinkNoOffFormat,
    ThinkLevel.ultra => l10nNow.thinkNoUltraFormat,
    _ => null,
  };

  /// OpenAI 的思考摘要要组织做过认证才给,没认证的整条请求 400。为了看思考把人整个
  /// 挡在外面不值:去掉摘要再发一次,照常出词,只是没有思考可看。
  ///
  /// 判据是报错原话里提没提摘要 / 认证 —— OpenAI 没给专门的错误码,而只凭 400 就重发
  /// 会把别的错(模型名写错)掩盖成一次白跑。
  @override
  Map<String, dynamic>? retryBody(
    Map<String, dynamic> body,
    int status,
    String error,
  ) {
    if (status != 400) return null;
    final r = body['reasoning'];
    if (r is! Map || !r.containsKey('summary')) return null;
    final e = error.toLowerCase();
    if (!e.contains('summar') && !e.contains('verif')) return null;
    return {
      ...body,
      'reasoning': {...r}..remove('summary'),
    };
  }

  /// `response.output_text.delta` 是正文;`response.reasoning_summary_text.delta`
  /// (官方推理模型的摘要)、`response.reasoning_text.delta`(gpt-oss 这类开源模型的原文)
  /// 是思考。
  @override
  LlmText parseDelta(Object? frame) {
    const none = (text: '', reasoning: '');
    if (frame is! Map) return none;
    final delta = frame['delta'] is String ? frame['delta'] as String : '';
    return switch (frame['type']) {
      'response.output_text.delta' => (text: delta, reasoning: ''),
      'response.reasoning_summary_text.delta' ||
      'response.reasoning_text.delta' => (text: '', reasoning: delta),
      // 摘要是分段写的(每段一个小标题),段与段之间空一行,不然全挤成一坨
      'response.reasoning_summary_part.added'
          when (frame['summary_index'] as num? ?? 0) > 0 =>
        (text: '', reasoning: '\n\n'),
      _ => none,
    };
  }

  @override
  String parseResponse(Object? body) {
    if (body is! Map) return '';
    final text = _output(body, 'message', 'output_text');
    // 有的中转在顶上多给一个拼好的 output_text(官方 SDK 才有的便利字段)
    return text.isNotEmpty ? text : (body['output_text']?.toString() ?? '');
  }

  @override
  String parseResponseReasoning(Object? body) {
    if (body is! Map) return '';
    return [
      _output(body, 'reasoning', 'summary_text', field: 'summary'),
      _output(body, 'reasoning', 'reasoning_text'),
    ].where((s) => s.trim().isNotEmpty).join('\n');
  }

  /// `output[]` 里 [itemType] 那几项的 [field] 下 [partType] 那几段文字。
  /// 正文在 message 的 content 里,思考摘要在 reasoning 的 summary 里;
  /// 多段之间空一行(摘要每段一个小标题)。
  static String _output(
    Map body,
    String itemType,
    String partType, {
    String field = 'content',
  }) {
    final output = body['output'];
    if (output is! List) return '';
    final parts = <String>[];
    for (final item in output) {
      if (item is! Map || item['type'] != itemType) continue;
      final list = item[field];
      if (list is! List) continue;
      for (final p in list) {
        if (p is Map && p['type'] == partType && p['text'] is String) {
          parts.add(p['text'] as String);
        }
      }
    }
    return parts.join(itemType == 'reasoning' ? '\n\n' : '');
  }

  /// 和 OpenAI 同一个列表接口:`{"data":[{"id":"gpt-5"}]}`
  @override
  List<String> parseModels(Object? body) =>
      body is Map ? modelIdsOf(body['data']) : const [];
}
