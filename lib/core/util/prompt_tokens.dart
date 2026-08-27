/// 提示词分词:去权重记号/括号/冒号 → 压空白 → 小写 → 逗号切词。
/// 灵感库那边判断「这条提示词里已经有哪些标签」用。
library;

String cleanPromptToken(String s) {
  var t = s.replaceAll(RegExp(r'[+-]?\d+(?:\.\d+)?::'), '');
  t = t.replaceAll(RegExp(r'[\[\]{}()]'), '');
  t = t.replaceAll(':', '');
  // 下划线归一为空格(提示词与词库两种写法都存在,双边同归一才配得上)
  t = t.replaceAll('_', ' ');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}

/// 逗号切词(中英文逗号)→ 清洗 → 去重集合。
Set<String> tokenizeSet(String text) {
  final out = <String>{};
  for (final p in text.split(RegExp(r'[，,]'))) {
    final t = cleanPromptToken(p);
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}
