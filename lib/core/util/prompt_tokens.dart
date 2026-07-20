/// 提示词分词与匹配(角色识别用,移植自 web 工具箱):
/// 去权重记号/括号/冒号 → 压空白 → 小写;LCS 用于 OC 串整体匹配。
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

/// 逗号切词,保序(OC 串 LCS 匹配用)。
List<String> tokenizeSeq(String text) {
  final out = <String>[];
  for (final p in text.split(RegExp(r'[，,]'))) {
    final t = cleanPromptToken(p);
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}

/// a 在 b 中的最长公共子序列占比(按 a 长度归一)。
double lcsRatio(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final n = a.length, m = b.length;
  var prev = List<int>.filled(m + 1, 0);
  var cur = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      cur[j] = a[i - 1] == b[j - 1]
          ? prev[j - 1] + 1
          : (prev[j] > cur[j - 1] ? prev[j] : cur[j - 1]);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[m] / n;
}
