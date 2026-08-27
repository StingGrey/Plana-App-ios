/// 法典词条里的 `charN` 多角色标记解析(对齐 web `utils/promptParser.ts`)。
///
/// 所长法典用 `char1：xxx, char2：yyy` 这套**人读约定**表示「这段归角色 N」,
/// NAI 本身不认识它 —— 不拆的话 `char1` `char2` 会作为字面 tag 发出去,角色
/// 特征全糊在一起,还白搭两个噪声词。现网数据里 NSFW 法典约 21%(2322/10914)、
/// 常规法典约 3%(192/6358)的词条带这个标记,不是边角情况。
///
/// **只对 NAI 有意义**:Anima / Krea 没有角色分离,调用方自行判断父类。
library;

/// 拆出来的一个角色。[index] 是 `charN` 里的 N(原样保留,用于命名与排序)。
class CodexCharPart {
  const CodexCharPart({
    required this.index,
    required this.positive,
    this.negative = '',
  });

  final int index;
  final String positive;
  final String negative;
}

/// 拆分结果。[base] 是第一个标记之前的公共部分(可能为空 —— 有的词条上来就是
/// `char1：`)。[characters] 为空表示这条没有多角色标记,按老路整段处理。
class CodexSplit {
  const CodexSplit({required this.base, required this.characters});

  final String base;
  final List<CodexCharPart> characters;

  bool get hasCharacters => characters.isNotEmpty;
}

/// 认三种写法(大小写不敏感,中英文冒号都吃):
///   `char1: …` / `char1：…`  → 该角色的正向
///   `[char1+] …`             → 同上
///   `[char1-] …`             → 该角色的**负向**(与同号的 `+` 合并成一张卡)
///
/// 标记前允许有换行或逗号并被一并吃掉 —— 否则公共部分会拖着一个尾逗号,
/// 角色内容会顶着一个头逗号。
final _charMark = RegExp(
  r'(?:[\n,]\s*)?(?:\[\s*char(\d+)\s*([+-])\s*\]|char(\d+)\s*[：:])',
  caseSensitive: false,
);

/// 收尾的逗号/空白:拆出来的每段都可能带,统一削掉。
final _trailingComma = RegExp(r'[,，]\s*$');

String _clean(String s) => s.trim().replaceAll(_trailingComma, '').trim();

/// 把词条内容拆成「公共部分 + 各角色」。没有标记时原样返回,[CodexSplit.characters] 为空。
CodexSplit splitCodexCharacters(String content) {
  final marks = _charMark.allMatches(content).toList();
  if (marks.isEmpty) {
    return CodexSplit(base: _clean(content), characters: const []);
  }

  final base = _clean(content.substring(0, marks.first.start));

  // 同一个编号可能出现两次(`[char1+]` 与 `[char1-]`),按编号归并成一张卡。
  final byNum = <int, ({String positive, String negative})>{};
  for (var i = 0; i < marks.length; i++) {
    final m = marks[i];
    final num = int.tryParse(m.group(1) ?? m.group(3) ?? '');
    if (num == null) continue;
    final end = i + 1 < marks.length ? marks[i + 1].start : content.length;
    final body = _clean(content.substring(m.end, end));
    final cur = byNum[num] ?? (positive: '', negative: '');
    byNum[num] = m.group(2) == '-'
        ? (positive: cur.positive, negative: body)
        : (positive: body, negative: cur.negative);
  }

  final nums = byNum.keys.toList()..sort();
  return CodexSplit(
    base: base,
    characters: [
      for (final n in nums)
        // 只有负向、没有正向的角色不成立(多半是词条自己写漏了),丢掉 ——
        // 建一张空正向的卡只会让人以为导入出了错。
        if (byNum[n]!.positive.isNotEmpty)
          CodexCharPart(
            index: n,
            positive: byNum[n]!.positive,
            negative: byNum[n]!.negative,
          ),
    ],
  );
}
