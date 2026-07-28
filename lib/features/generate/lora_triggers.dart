/// LoRA 触发词 ↔ 正向提示词 的读写(移植 web LeftSidebar 同名工具)。
///
/// 触发词不走服务端拼接(载荷 triggers 恒传 `[]`),由用户在卡片上逐条点击
/// 直接写进/移出正向词框 —— 所见即所得。一个触发词条目可能是一整套逗号
/// 分隔 tag(如 "grey hair, long hair"),统一按单个 tag 处理。
///
/// 与 web 相同的已知取舍:按逗号切分不解析 `N::…::` 权重组语法,组内逗号
/// 会被当成 tag 边界;触发词本身不含该语法,实际影响仅限用户手写的组。
library;

final _splitRe = RegExp(r'[,，]');

/// 归一化(用于比较/去重):小写、去两侧空白、剥外层权重括号与 ":权重" 后缀。
String normalizeTagKey(String t) {
  var s = t.trim().toLowerCase();
  s = s.replaceFirst(RegExp(r'^[({\[]+'), '');
  s = s.replaceFirst(RegExp(r'[)}\]]+$'), '');
  s = s.replaceFirst(RegExp(r':\s*-?\d+(?:\.\d+)?$'), '');
  return s.trim();
}

Set<String> _keysOf(String prompt) => {
  for (final p in prompt.split(_splitRe))
    if (normalizeTagKey(p).isNotEmpty) normalizeTagKey(p),
};

/// 该触发词条目的所有 tag 是否都已在正向词里。
bool promptHasTrigger(String prompt, String trigger) {
  final have = _keysOf(prompt);
  final tags = [
    for (final t in trigger.split(_splitRe))
      if (normalizeTagKey(t).isNotEmpty) normalizeTagKey(t),
  ];
  return tags.isNotEmpty && tags.every(have.contains);
}

/// 把触发词逐 tag 去重后追加到正向词末尾。
String appendTriggerToPrompt(String prompt, String trigger) {
  final have = _keysOf(prompt);
  final add = <String>[];
  for (final raw in trigger.split(_splitRe)) {
    final tag = raw.trim();
    final key = normalizeTagKey(raw);
    if (key.isNotEmpty && !have.contains(key)) {
      have.add(key);
      add.add(tag);
    }
  }
  if (add.isEmpty) return prompt;
  final joined = add.join(', ');
  if (prompt.trim().isEmpty) return joined;
  return '${prompt.replaceFirst(RegExp(r'\s*[,，]\s*$'), '')}, $joined';
}

/// 从正向词里移除该触发词条目的 tag(带权重括号/后缀的同名 tag 一并算命中)。
String removeTriggerFromPrompt(String prompt, String trigger) {
  final toRemove = {
    for (final t in trigger.split(_splitRe))
      if (normalizeTagKey(t).isNotEmpty) normalizeTagKey(t),
  };
  return prompt
      .split(_splitRe)
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && !toRemove.contains(normalizeTagKey(s)))
      .join(', ');
}
