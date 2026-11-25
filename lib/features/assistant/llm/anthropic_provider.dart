import '../../../l10n/l10n.dart';
import '../assistant_settings.dart' show ThinkLevel;
import 'http_provider.dart';
import 'llm_provider.dart';

/// 还在用固定思考预算(`budget_tokens`)的 Claude:3.x、4、4.1、4.5。
///
/// 4.6 起换成了自适应思考,4.7 起 `budget_tokens` 直接 400 —— 按模型名分两路。
/// 认不出的名字(中转起的别名)按新的走:老模型在下线,新模型越来越多。
/// 版本号可能写成 `4-5` 也可能写成 `4.5`(OpenRouter),后面可能跟日期。
final _claudeLegacy = RegExp(
  r'claude-3|(?:opus|sonnet|haiku)-4(?:[.-][015])?(?=$|-20\d{6}|[^0-9.-]|[.-][^0-9])',
  caseSensitive: false,
);

/// 思考关不掉、默认就在想的 Claude(5 代起,以及 Fable / Mythos)。
///
/// 这几个模型默认**不回思考的字**(`display` 默认 `omitted`,思考块是空串),
/// 要显示得明着要 `summarized`;想关也关不掉,`disabled` 是 400,只能把力度调低。
final _claudeAlwaysThinks = RegExp(
  r'(?:opus|sonnet|haiku)-[5-9]|fable|mythos',
  caseSensitive: false,
);

/// Claude 的缓存标记。Anthropic 不标就不缓存,每一跳都按全价重算整段系统提示和历史;
/// OpenAI、Gemini 按前缀自动缓存,不用标。默认 5 分钟,读一次续一次。
const _cache = {'type': 'ephemeral'};

/// Anthropic(`/messages`,`x-api-key` + `anthropic-version`)。
class AnthropicProvider extends HttpLlmProvider {
  AnthropicProvider(super.endpoint);

  bool get _legacy => _claudeLegacy.hasMatch(endpoint.model);

  @override
  Map<String, String> get authHeaders => {
    'x-api-key': apiKey,
    'anthropic-version': '2023-06-01',
  };

  @override
  Map<String, dynamic> requestBody(LlmRequest r, {required bool stream}) => {
    'model': endpoint.model,
    // 必填,没有「不限」。老模型开了思考还得大于思考预算(预算是从它里面切出去的);
    // 新模型(自适应思考)想多少由它自己定,同样从这里面扣,给少了会想到一半被截断
    'max_tokens': _legacy ? 4096 + _budget(r.think) : 16000,
    // 系统提示整段一个缓存点:规则、工具层、出图格式几千上万字,模式不变就逐字不变
    if (r.system.isNotEmpty)
      'system': [
        {'type': 'text', 'text': r.system, 'cache_control': _cache},
      ],
    'messages': [
      for (final (i, m) in r.messages.indexed)
        {
          'role': m.role,
          'content': _content(m, cache: i >= r.messages.length - 2),
        },
    ],
    if (stream) 'stream': true,
    ...thinkFields(r.think),
  };

  /// 一条消息的 content。[cache] = 挂缓存标记,只给最后两条:
  ///   · 最后一条是这一跳新加的,下一跳(查完资料回来)从它接着读;
  ///   · 倒数第二条在每轮第一跳是历史的最后一条 —— 本轮那条用户消息带着画布和资料块,
  ///     下一轮回带时只剩原话,对不上;历史末尾这个点下一轮还在,从这儿读。
  /// 一共三个缓存点,上限是四个。标记只能挂在块上,所以带标记的纯文字也得换成分段数组。
  static Object _content(LlmMessage m, {required bool cache}) {
    if (!cache && m.images.isEmpty) return m.content;
    final blocks = <Map<String, dynamic>>[
      for (final i in m.images)
        {
          'type': 'image',
          'source': {'type': 'base64', 'media_type': i.mime, 'data': i.data},
        },
      if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
    ];
    // 又没字又没图:挂不了(Claude 拒空 text 块),原样发
    if (blocks.isEmpty) return m.content;
    if (cache) blocks.last['cache_control'] = _cache;
    return blocks;
  }

  /// 老模型的思考预算(token)。0 = 不开;下限是它自己规定的 1024。
  static int _budget(ThinkLevel l) => switch (l) {
    ThinkLevel.auto || ThinkLevel.off => 0,
    ThinkLevel.low => 1024,
    ThinkLevel.medium => 4096,
    ThinkLevel.high => 8192,
    ThinkLevel.ultra => 16384,
  };

  /// 老模型「关」「自动」都是不带 thinking 字段(它们默认不想)。
  /// 新模型用自适应思考,力度走 `output_config.effort`,要 `summarized` 才回思考的字。
  @override
  Map<String, dynamic> thinkFields(ThinkLevel level) {
    if (_legacy) {
      final budget = _budget(level);
      if (budget == 0) return const {};
      return {
        'thinking': {'type': 'enabled', 'budget_tokens': budget},
      };
    }
    const adaptive = {'type': 'adaptive', 'display': 'summarized'};
    final alwaysOn = _claudeAlwaysThinks.hasMatch(endpoint.model);
    return switch (level) {
      // 4.6 ~ 4.8 默认不想,自动就不替它开;5 代默认在想,补上「给我看」
      ThinkLevel.auto => alwaysOn ? const {'thinking': adaptive} : const {},
      // 4.6 ~ 4.8 不带 thinking 就是不想;5 代关不掉(disabled 是 400),压到最低力度
      ThinkLevel.off =>
        alwaysOn
            ? const {
                'output_config': {'effort': 'low'},
              }
            : const {},
      _ => {
        'thinking': adaptive,
        'output_config': {
          'effort': switch (level) {
            ThinkLevel.low => 'low',
            ThinkLevel.medium => 'medium',
            ThinkLevel.high => 'high',
            _ => 'max',
          },
        },
      },
    };
  }

  @override
  String? thinkNote(ThinkLevel level) =>
      level == ThinkLevel.off &&
          !_legacy &&
          _claudeAlwaysThinks.hasMatch(endpoint.model)
      ? l10nNow.thinkNoOffModel
      : null;

  /// `text_delta` / `thinking_delta`;`message_delta` 这类也带 delta,但不带字。
  @override
  LlmText parseDelta(Object? frame) {
    const none = (text: '', reasoning: '');
    if (frame is! Map) return none;
    final d = frame['delta'];
    if (d is! Map) return none;
    return switch (d['type']) {
      'text_delta' => (
        text: d['text'] is String ? d['text'] as String : '',
        reasoning: '',
      ),
      'thinking_delta' => (
        text: '',
        reasoning: d['thinking'] is String ? d['thinking'] as String : '',
      ),
      _ => none,
    };
  }

  /// `content[]` 里只取 type=text 那几段。
  @override
  String parseResponse(Object? body) => _blocks(body, 'text', 'text');

  /// `content[]` 里 type=thinking 那几段。
  @override
  String parseResponseReasoning(Object? body) =>
      _blocks(body, 'thinking', 'thinking');

  static String _blocks(Object? body, String type, String field) {
    if (body is! Map) return '';
    final content = body['content'];
    if (content is! List) return '';
    return [
      for (final p in content)
        if (p is Map && p['type'] == type) p[field]?.toString() ?? '',
    ].join();
  }

  /// `{"data":[{"id":"claude-sonnet-4-6"}]}`
  @override
  List<String> parseModels(Object? body) =>
      body is Map ? modelIdsOf(body['data']) : const [];
}
