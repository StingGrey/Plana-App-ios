import 'editor_models.dart';

enum PromptBlacklistMode {
  /// 命中后立即从输入中移除(原有行为)。
  remove,

  /// 保留原文并标红,由用户检查后决定是否一键删除。
  highlight,
}

/// 黑名单匹配口径:忽略大小写,并把连续空白与下划线视为同一种分词符。
///
/// Danbooru 等站点复制出来通常是 `huge_penis`,而 app 内展示/编辑通常是
/// `huge penis`;两者必须落到同一个 key,否则黑名单对复制粘贴几乎无效。
String normalizePromptBlacklistTag(String tag) =>
    tag.trim().toLowerCase().replaceAll(RegExp(r'[_\s]+'), ' ');

/// 清洗并按匹配 key 去重。保存规范形态(空格分词),设置页再次打开时也不会
/// 同时出现 `huge penis` / `huge_penis` 两条实际等价的规则。
List<String> canonicalPromptBlacklist(Iterable<String> entries) {
  final out = <String>[];
  final seen = <String>{};
  for (final entry in entries) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) continue;
    // `/.../` 是正则规则,内部的下划线、空格与大小写都属于表达式本身,
    // 不能像普通 tag 一样擅自改写。匹配时另外对 tag 的原文与规范形态各跑一次。
    if (isPromptBlacklistRegex(trimmed)) {
      if (seen.add('regex:$trimmed')) out.add(trimmed);
      continue;
    }
    final normalized = normalizePromptBlacklistTag(trimmed);
    if (normalized.isNotEmpty && seen.add('tag:$normalized')) {
      out.add(normalized);
    }
  }
  return out;
}

/// 设置页文本口径:一行一条,也接受中英文逗号,方便直接粘一小串 tag。
List<String> parsePromptBlacklistText(String text) =>
    canonicalPromptBlacklist(text.split(RegExp(r'[,，\r\n]+')));

String promptBlacklistText(Iterable<String> entries) =>
    canonicalPromptBlacklist(entries).join('\n');

bool isPromptTagBlacklisted(String tag, Iterable<String> blacklist) {
  final normalized = normalizePromptBlacklistTag(tag);
  if (normalized.isEmpty) return false;
  final underscored = normalized.replaceAll(' ', '_');
  for (final entry in blacklist) {
    final rule = entry.trim();
    if (isPromptBlacklistRegex(rule)) {
      final regex = _promptBlacklistRegex(rule);
      if (regex != null &&
          (regex.hasMatch(tag) ||
              regex.hasMatch(normalized) ||
              regex.hasMatch(underscored))) {
        return true;
      }
      continue;
    }
    if (normalizePromptBlacklistTag(rule) == normalized) return true;
  }
  return false;
}

/// `/penis/` 形态视为正则。只认首尾斜线,不扩展 flags 语法,让设置输入保持直观。
bool isPromptBlacklistRegex(String entry) =>
    entry.length >= 2 && entry.startsWith('/') && entry.endsWith('/');

final _regexCache = <String, RegExp?>{};

RegExp? _promptBlacklistRegex(String rule) {
  if (_regexCache.containsKey(rule)) return _regexCache[rule];
  RegExp? compiled;
  try {
    compiled = RegExp(rule.substring(1, rule.length - 1), caseSensitive: false);
  } on FormatException {
    compiled = null; // 输入中的坏正则不该让编辑器崩掉
  }
  if (_regexCache.length >= 200) _regexCache.clear();
  _regexCache[rule] = compiled;
  return compiled;
}

/// 当前提示词中全部命中的完整 tag。正则只负责判断是否命中,返回/删除单位
/// 始终是 [parseToks] 按逗号切出的整枚 Tok,绝不在 tag 内部做子串替换。
List<Tok> blacklistedPromptToks(
  String text,
  Iterable<String> blacklist, {
  Map<String, String> foldBodies = const {},
}) {
  if (text.isEmpty || blacklist.isEmpty) return const [];
  final foldRanges = {
    for (final fold in parseFoldRefs(text, foldBodies)) (fold.start, fold.end),
  };
  return [
    for (final tok in parseToks(text))
      if (!foldRanges.contains((tok.segStart, tok.segEnd)) &&
          isPromptTagBlacklisted(tok.name, blacklist))
        tok,
  ];
}

class PromptBlacklistResult {
  const PromptBlacklistResult({
    required this.text,
    required this.cursor,
    required this.removedCount,
  });

  final String text;
  final int cursor;
  final int removedCount;

  bool get changed => removedCount > 0;
}

/// 从提示词中删除命中黑名单的**完整 tag**。
///
/// - 通过 [parseToks] 读名字,所以 `{tag}` / `1.2::tag::` / `~tag~` 同样能删;
/// - 只做完整 tag 匹配,`girl` 不会误删 `girl on top`;
/// - [completedOnly] 用于逐字输入:只删右侧已有逗号/换行的已提交 tag。
///   粘贴与程序化落词传 false,末尾最后一枚也会立即过滤;
/// - [foldBodies] 用于跳过编辑器内部折叠占位符,避免规则碰巧与折叠标题同名
///   时把整个折叠误当普通 tag 删除。
PromptBlacklistResult filterPromptBlacklist(
  String text,
  Iterable<String> blacklist, {
  int? cursor,
  bool completedOnly = false,
  Map<String, String> foldBodies = const {},
}) {
  var caret = (cursor ?? text.length).clamp(0, text.length);
  final victims = blacklistedPromptToks(text, blacklist, foldBodies: foldBodies)
      .where(
        (tok) => !completedOnly || _hasPromptTerminatorAfter(text, tok.segEnd),
      )
      .toList();
  if (victims.isEmpty) {
    return PromptBlacklistResult(text: text, cursor: caret, removedCount: 0);
  }

  var out = text;
  // 倒序删除,前方 Tok 的原始下标不会漂移。每次按实际删掉的区间同步光标,
  // 粘贴一长串后光标仍留在原来内容对应的位置,不会一律跳到开头。
  for (final tok in victims.reversed) {
    final beforeLength = out.length;
    final (next, start) = deleteTok(out, tok);
    final removedLength = beforeLength - next.length;
    final end = start + removedLength;
    if (caret > start) {
      caret = caret <= end ? start : caret - removedLength;
    }
    out = next;
  }
  return PromptBlacklistResult(
    text: out,
    cursor: caret.clamp(0, out.length),
    removedCount: victims.length,
  );
}

bool _hasPromptTerminatorAfter(String text, int end) {
  var at = end;
  while (at < text.length && (text[at] == ' ' || text[at] == '\t')) {
    at++;
  }
  return at < text.length &&
      (text[at] == ',' || text[at] == '，' || text[at] == '\n');
}
