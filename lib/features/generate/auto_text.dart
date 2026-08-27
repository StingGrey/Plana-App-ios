/// autoText —— 把提示词里**引号包起来的内容**自动转成 NAI 的 `text:` 块。
///
/// V4.5 起画面里可以生成文字,写法是提示词里放 `text: 要写的字`。V5 新增了 `autoText`
/// 能力(能力表里 4.5 是 false、V5 是 true),做的是语法糖:用户直接打引号,客户端替他转。
///
/// 逐条照抄 web `utils/autoText.ts`(它又是逐条照抄官方实现),包括那几个不写下来
/// 就会忘的细节:
/// - **用户手写了 `text:` 就完全不插手**(正则不分大小写)。
/// - 自动加的块用 `teXt:` 这个**大小写变体**当标记 —— 剥离时靠它区分「自动加的」和
///   「用户手写的」。
/// - 英文撇号不会误判:`'` 只在前一个字符不是字母数字时才当引号开头,收尾同理。
///   所以 `don't`、`it's` 安全。
/// - 多角色按**阅读顺序**收集:先按 y 分行,行内再按 x 排。
/// - 抽出来的内容里 CJK 字符占比 **> 30%** 时整体**反转顺序**(竖排右起的阅读习惯)。
///
/// 只在模型支持时调用(V5),见调用方的 `isNai5Model` 判断。
library;

/// 提示词分块的分隔符与上限,与官方一致。
const _chunkSep = '|';
const _chunkEscape = '||';
const _maxChunks = 6;

/// 私有码点占位,用来在切块时保护 `||…||` 里的竖线。
const _placeholderPipe = '\u{103B9}';
const _placeholderEscape = '\u{12137}';

/// 用户手写的 `text:`(不分大小写);命中就整个不插手。
///
/// 提示词预设拼后缀时也要用它 —— 质量词不能落进 `text:` 块里,所以导出去共用
/// (见 prompt_presets.dart)。**不分大小写**,所以自动加的 `teXt:` 变体也一并命中,
/// 预设与 autoText 谁先谁后都不影响。
final userTextMarker = RegExp(
  r'(?:^|\s|[,.:\[\]{}、。])text:(?!:)',
  caseSensitive: false,
);

/// 自动加的块用这个大小写变体,剥离时靠它认出来。
const _autoMarker = 'teXt:';
final _autoMarkerRe = RegExp(r'(?:^|\s|[,.:\[\]{}、。])teXt:(?!:)');

/// 支持的引号对(中英文都收)。
const _quotePairs = <String, String>{
  '"': '"',
  '“': '”', // “ ”
  '「': '」', // 「 」
  "'": "'",
  '‘': '’', // ‘ ’
};

/// y 方向的分行阈值(归一化坐标)。
const _lineTotalThreshold = 0.15;
const _lineGapThreshold = 0.1;

final _cjkRe = RegExp(
  '[　-〿぀-ゟ゠-ヿ'
  '＀-ﾟ一-龯㐀-䶿]',
);

final _alnumRe = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// 参与 autoText 的一个角色:提示词 + 归一化中心坐标(用于按阅读顺序排)。
class AutoTextChar {
  const AutoTextChar({required this.prompt, this.enabled = true, this.center});

  final String prompt;
  final bool enabled;

  /// 归一化中心坐标;缺省视为原顺序。
  final ({double x, double y})? center;
}

/// 把提示词切成块。`||…||` 之间的竖线不算分隔符,先用私有码点挡住再切。
List<String> splitPromptChunks(String prompt) {
  final segs = prompt.split(_chunkEscape);
  final guarded = [
    for (var i = 0; i < segs.length; i++)
      if (i.isOdd) segs[i].split(_chunkSep).join(_placeholderPipe) else segs[i],
  ].join(_placeholderEscape).split(_chunkSep);

  final chunks = [...guarded.take(_maxChunks - 1)];
  // 超出上限的部分全部并进最后一块,而不是丢掉
  if (guarded.length > _maxChunks - 1) {
    chunks.add(guarded.skip(_maxChunks - 1).join(_chunkSep));
  }
  return [
    for (final c in chunks)
      c
          .split(_placeholderPipe)
          .join(_chunkSep)
          .split(_placeholderEscape)
          .join(_chunkEscape),
  ];
}

bool _isAlnum(String? ch) => ch != null && _alnumRe.hasMatch(ch);

String? _at(String s, int i) => i >= 0 && i < s.length ? s[i] : null;

/// 抽出一段文字里所有引号包起来的内容(去空白、丢空串)。
List<String> extractQuoted(String text) {
  final out = <String>[];
  var i = 0;
  while (i < text.length) {
    final close = _quotePairs[text[i]];
    // 直角撇号前面挨着字母数字时是 don't 的那个撇号,不是引号
    if (close == null || (text[i] == "'" && _isAlnum(_at(text, i - 1)))) {
      i++;
      continue;
    }
    final isApostrophe = close == "'" || close == '’';
    var j = i + 1;
    while (j < text.length &&
        (text[j] != close || (isApostrophe && _isAlnum(_at(text, j + 1))))) {
      j++;
    }
    if (j >= text.length) {
      // 没有配对的收尾引号,当普通字符跳过
      i++;
      continue;
    }
    final inner = text.substring(i + 1, j).trim();
    if (inner.isNotEmpty) out.add(inner);
    i = j + 1;
  }
  return out;
}

double _y(AutoTextChar c) => c.center?.y ?? 0;
double _x(AutoTextChar c) => c.center?.x ?? 0;

/// 按 y 递归分行:整体跨度和最大间距都够小就算同一行。
List<List<AutoTextChar>> _splitIntoLines(List<AutoTextChar> chars) {
  if (chars.length <= 1) return [chars];
  final total = _y(chars.last) - _y(chars.first);
  var splitAt = 1;
  var maxGap = double.negativeInfinity;
  for (var i = 1; i < chars.length; i++) {
    final gap = _y(chars[i]) - _y(chars[i - 1]);
    if (gap > maxGap) {
      maxGap = gap;
      splitAt = i;
    }
  }
  if (total <= _lineTotalThreshold && maxGap <= _lineGapThreshold) {
    return [chars];
  }
  return [
    ..._splitIntoLines(chars.sublist(0, splitAt)),
    ..._splitIntoLines(chars.sublist(splitAt)),
  ];
}

/// 阅读顺序:先按 y 分行,行内按 x 从左到右。
List<AutoTextChar> _readingOrder(List<AutoTextChar> chars) {
  final byY = [...chars]..sort((a, b) => _y(a).compareTo(_y(b)));
  return [
    for (final line in _splitIntoLines(byY))
      ...[...line]..sort((a, b) => _x(a).compareTo(_x(b))),
  ];
}

bool _isMostlyCjk(String text) {
  if (text.isEmpty) return false;
  final hits = _cjkRe.allMatches(text).length;
  return hits > 0 && hits / text.length > 0.3;
}

List<AutoTextChar> _enabled(List<AutoTextChar> chars) => [
  for (final c in chars)
    if (c.enabled && c.prompt.isNotEmpty) c,
];

/// 收集 base + 各角色里的引号内容,按阅读顺序,CJK 时整体反转。
List<String> _collectTexts(
  String base,
  List<AutoTextChar> chars,
  bool useCoords,
) {
  final chosen = _enabled(chars);
  final ordered = useCoords ? _readingOrder(chosen) : chosen;
  final groups = [
    extractQuoted(base),
    for (final c in ordered) extractQuoted(c.prompt),
  ];
  if (_isMostlyCjk(groups.expand((g) => g).join())) {
    for (final g in groups) {
      final r = g.reversed.toList();
      g
        ..clear()
        ..addAll(r);
    }
  }
  return [for (final g in groups) ...g];
}

/// 把引号内容转成 `teXt:` 块追加到第一块提示词末尾。
/// 用户已手写 `text:`、或压根没有引号内容时原样返回。
String applyAutoText(
  String prompt, {
  List<AutoTextChar> characters = const [],
  bool useCoords = false,
}) {
  final chosen = _enabled(characters);
  if (userTextMarker.hasMatch(prompt) ||
      chosen.any((c) => userTextMarker.hasMatch(c.prompt))) {
    return prompt;
  }
  final chunks = splitPromptChunks(prompt);
  final texts = _collectTexts(
    chunks.isEmpty ? '' : chunks.first,
    characters,
    useCoords,
  );
  if (texts.isEmpty) return prompt;

  final block = '$_autoMarker ${texts.join('\n\n')}';
  final head = (chunks.isEmpty ? '' : chunks.first).replaceAll(
    RegExp(r'[\s,]+$'),
    '',
  );
  final out = chunks.isEmpty ? <String>[''] : [...chunks];
  out[0] = head.isNotEmpty ? '$head, $block' : block;
  return out.join(_chunkSep);
}

/// 逆操作:把自动加的 `teXt:` 块剥掉,还原用户原文。
///
/// 判定方式是**重算一遍**:算出来的块和现有的一致才认定是自动加的。不一致说明用户
/// 手改过,原样保留 —— 不能靠标记本身判断,否则会把用户自己写的 `teXt:` 也吃掉。
String stripAutoText(
  String prompt, {
  List<AutoTextChar> characters = const [],
  bool useCoords = false,
}) => [
  for (final chunk in splitPromptChunks(prompt))
    () {
      final m = _autoMarkerRe.firstMatch(chunk);
      if (m == null) return chunk;
      final head = chunk.substring(0, m.start);
      final tail = chunk.substring(m.end).trim();
      if (tail != _collectTexts(head, characters, useCoords).join('\n\n')) {
        return chunk;
      }
      return head.replaceAll(RegExp(r'[\s,]+$'), '');
    }(),
].join(_chunkSep);
