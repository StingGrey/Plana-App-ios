/// 补全数据源(占位词库)。
/// v1 = 内置精选词库 + Danbooru 公共 API(后续接);v2 再上 AI 推荐与画师串。
/// 此文件不依赖任何编辑器模型,避免循环引用。
library;

enum SuggestionKind { tag, character, oc, work, artist }

class Suggestion {
  const Suggestion({
    required this.text,
    required this.kind,
    this.trans,
    this.source,
    this.note,
    this.count = 0,
    this.insertText,
    this.natural = false,
    this.randomPick,
  });

  /// 英文标签 / 实体名
  final String text;
  final SuggestionKind kind;

  /// 实际插入 prompt 的载荷(为空则用 [text])。画师=artist_string、OC=tag_group;
  /// 作品**不用**这个字段(默认插作品 tag 本身),随机角色见 [randomPick]。
  final String? insertText;

  /// 「翻译为英文」自然语言行:选中时才把 [text](中文)整句翻成英文再替换。
  final bool natural;

  /// 中文翻译
  final String? trans;

  /// 来源作品(角色用)
  final String? source;

  /// 附注(OC/作品的插入说明)
  final String? note;

  /// 热度(0 = 不显示)
  final int count;

  /// 作品行预抽的随机角色。**不放进 [insertText]**:那样默认插入就变成随机角色,
  /// 而作品的默认行为是插入作品 tag 本身,随机抽取只归补全面板的骰子按钮。
  final String? randomPick;

  Suggestion copyWith({
    String? text,
    SuggestionKind? kind,
    String? trans,
    String? source,
    String? note,
    int? count,
    String? insertText,
    bool? natural,
    String? randomPick,
  }) => Suggestion(
    text: text ?? this.text,
    kind: kind ?? this.kind,
    trans: trans ?? this.trans,
    source: source ?? this.source,
    note: note ?? this.note,
    count: count ?? this.count,
    insertText: insertText ?? this.insertText,
    natural: natural ?? this.natural,
    randomPick: randomPick ?? this.randomPick,
  );
}

// ---- 网络回填缓存(注音/热度)----
// 补全引擎每查到一个标签的中文名/热度就写入这里,注音层([translationOf])与
// 词条栏([countOf])随后同步反查,免得网络来源的译名/热度显示不出来。

final Map<String, String> _transCache = {};
final Map<String, int> _countCache = {};

/// 反查缓存的版本号:每次回填自增。注音层据此判断「文本没变但翻译到了」
/// 需要重绘(painter 的 shouldRepaint 只比文本,不比缓存内容)。
int _transRev = 0;
int get transCacheRev => _transRev;

/// 多译合一的字符串(逗号/顿号/斜杠/分号分隔)只留第一段——注音要短。
/// 各来源(离线库/wiki 中文名 join/共享翻译库/LLM)在此统一兜底。
String? _firstTrans(String? zh) {
  if (zh == null) return null;
  var cut = zh.length;
  for (final s in const [',', '，', '、', '/', ';', '；']) {
    final i = zh.indexOf(s);
    if (i >= 0 && i < cut) cut = i;
  }
  final first = zh.substring(0, cut).trim();
  return first.isEmpty ? null : first;
}

/// 反查缓存上限。**必须高于离线库全量**:进编辑器时 `LocalTagDb.warmTagMeta`
/// 一次就灌进 7 万条译文 / 9 万条热度,而这里满了是整表清空 —— 上限写 20000
/// 的话灌注途中自己清了三四次,最后只剩尾部那截最冷门的标签。词库按热度降序,
/// 被清掉的恰恰是 1girl、solo 这些最常用的,注音层和补全反查全查不到。
/// 15 万给灌注之后的网络回填留了余量。
const _metaCap = 150000;

/// 回填某标签的中文名/热度(键用小写形式)。由 `TagCompletion` 与离线库灌注调用。
/// 上限防无界增长(清空只影响反查显示,重查询即回填)。
void cacheTagMeta(String text, {String? trans, int? count}) {
  final k = text.trim().toLowerCase();
  final t = _firstTrans(trans);
  if (t != null) {
    if (_transCache.length > _metaCap) _transCache.clear();
    _transCache[k] = t;
    _transRev++;
  }
  if (count != null && count > 0) {
    if (_countCache.length > _metaCap) _countCache.clear();
    _countCache[k] = count;
  }
}

/// 一次查询的分类结果
class SuggestResult {
  const SuggestResult({
    this.characters = const [],
    this.ocs = const [],
    this.works = const [],
    this.artists = const [],
    this.tags = const [],
  });

  final List<Suggestion> characters;
  final List<Suggestion> ocs;
  final List<Suggestion> works;
  final List<Suggestion> artists;
  final List<Suggestion> tags;

  bool get hasEntities =>
      characters.isNotEmpty ||
      ocs.isNotEmpty ||
      works.isNotEmpty ||
      artists.isNotEmpty;

  bool get isEmpty => tags.isEmpty && !hasEntities;

  int get total =>
      characters.length +
      ocs.length +
      works.length +
      artists.length +
      tags.length;

  /// 横向态排列:实体(画师/角色/OC/作品)优先,后接标签
  List<Suggestion> get flat => [
    ...artists,
    ...characters,
    ...ocs,
    ...works,
    ...tags,
  ];
}

/// 热度缩写:1200 → 1.2k,320000 → 320k;<1000 不显示(返回 null)
String? formatCount(int n) {
  if (n < 1000) return null;
  if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '${(n / 1000).round()}k';
}

// ---- 内置词库(占位) ----

const _tags = <Suggestion>[
  Suggestion(
    text: 'yukata',
    kind: SuggestionKind.tag,
    trans: '浴衣',
    count: 320000,
  ),
  Suggestion(
    text: 'yuki onna',
    kind: SuggestionKind.tag,
    trans: '雪女',
    count: 5200,
  ),
  Suggestion(
    text: 'yukikaze',
    kind: SuggestionKind.tag,
    trans: '雪风',
    count: 900,
  ),
  Suggestion(
    text: 'yukkuri shiteitte ne',
    kind: SuggestionKind.tag,
    trans: '油库里',
    count: 8100,
  ),
  Suggestion(
    text: '1girl',
    kind: SuggestionKind.tag,
    trans: '1个女孩',
    count: 6200000,
  ),
  Suggestion(
    text: '1boy',
    kind: SuggestionKind.tag,
    trans: '1个男孩',
    count: 1400000,
  ),
  Suggestion(
    text: 'solo',
    kind: SuggestionKind.tag,
    trans: '单人',
    count: 5100000,
  ),
  Suggestion(
    text: 'silver hair',
    kind: SuggestionKind.tag,
    trans: '银发',
    count: 210000,
  ),
  Suggestion(
    text: 'silver long hair',
    kind: SuggestionKind.tag,
    trans: '银色长发',
    count: 34000,
  ),
  Suggestion(
    text: 'long hair',
    kind: SuggestionKind.tag,
    trans: '长发',
    count: 4300000,
  ),
  Suggestion(
    text: 'red eyes',
    kind: SuggestionKind.tag,
    trans: '红眼',
    count: 890000,
  ),
  Suggestion(
    text: 'gothic dress',
    kind: SuggestionKind.tag,
    trans: '哥特连衣裙',
    count: 12000,
  ),
  Suggestion(
    text: 'smile',
    kind: SuggestionKind.tag,
    trans: '微笑',
    count: 3100000,
  ),
  Suggestion(
    text: 'moonlit rooftop',
    kind: SuggestionKind.tag,
    trans: '月夜屋顶',
    count: 640,
  ),
  Suggestion(
    text: 'full moon',
    kind: SuggestionKind.tag,
    trans: '满月',
    count: 96000,
  ),
  Suggestion(
    text: 'petals',
    kind: SuggestionKind.tag,
    trans: '花瓣',
    count: 74000,
  ),
  Suggestion(
    text: 'blue sky',
    kind: SuggestionKind.tag,
    trans: '蓝天',
    count: 520000,
  ),
  Suggestion(
    text: 'cloud',
    kind: SuggestionKind.tag,
    trans: '云',
    count: 480000,
  ),
  Suggestion(
    text: 'cityscape',
    kind: SuggestionKind.tag,
    trans: '城市景观',
    count: 41000,
  ),
  Suggestion(
    text: 'cinematic lighting',
    kind: SuggestionKind.tag,
    trans: '电影感光照',
    count: 38000,
  ),
  Suggestion(
    text: 'chiaroscuro',
    kind: SuggestionKind.tag,
    trans: '明暗对比',
    count: 5600,
  ),
  Suggestion(
    text: 'highly detailed',
    kind: SuggestionKind.tag,
    trans: '高度精细',
    count: 260000,
  ),
  Suggestion(
    text: 'best quality',
    kind: SuggestionKind.tag,
    trans: '最佳画质',
    count: 990000,
  ),
  Suggestion(
    text: 'masterpiece',
    kind: SuggestionKind.tag,
    trans: '杰作',
    count: 1200000,
  ),
  Suggestion(
    text: 'lowres',
    kind: SuggestionKind.tag,
    trans: '低分辨率',
    count: 130000,
  ),
  Suggestion(
    text: 'bad anatomy',
    kind: SuggestionKind.tag,
    trans: '解剖错误',
    count: 210000,
  ),
  Suggestion(
    text: 'bad hands',
    kind: SuggestionKind.tag,
    trans: '手部畸形',
    count: 180000,
  ),
  Suggestion(
    text: 'jpeg artifacts',
    kind: SuggestionKind.tag,
    trans: 'JPEG 伪影',
    count: 90000,
  ),
];

const _characters = <Suggestion>[
  Suggestion(
    text: 'yukinoshita yukino',
    kind: SuggestionKind.character,
    trans: '雪之下雪乃',
    source: '我的青春恋爱物语',
    count: 45000,
  ),
  Suggestion(
    text: 'yuuki asuna',
    kind: SuggestionKind.character,
    trans: '结城明日奈',
    source: '刀剑神域',
    count: 62000,
  ),
  Suggestion(
    text: 'yuki nagato',
    kind: SuggestionKind.character,
    trans: '长门有希',
    source: '凉宫春日的忧郁',
    count: 28000,
  ),
  Suggestion(
    text: 'hatsune miku',
    kind: SuggestionKind.character,
    trans: '初音未来',
    source: 'VOCALOID',
    count: 520000,
  ),
];

const _ocs = <Suggestion>[
  Suggestion(
    text: '雪莉',
    kind: SuggestionKind.oc,
    note: '插入为角色配置(正/负两段)',
    trans: '我的 OC',
  ),
];

const _works = <Suggestion>[
  Suggestion(
    text: 'yuru yuri',
    kind: SuggestionKind.work,
    trans: '摇曳百合',
    note: '12 个角色 · 点骰子随机抽取',
    count: 15000,
  ),
  Suggestion(
    text: 'sword art online',
    kind: SuggestionKind.work,
    trans: '刀剑神域',
    note: '48 个角色 · 点骰子随机抽取',
    count: 88000,
  ),
];

bool _hasCjk(String s) => s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

/// 匹配:英文按前缀/子串,中文按译名/来源子串;返回排序权重(越小越靠前,-1=不匹配)
int _rank(Suggestion s, String qLower, String qRaw, bool cjk) {
  if (cjk) {
    if ((s.trans?.contains(qRaw) ?? false)) return 0;
    if ((s.source?.contains(qRaw) ?? false)) return 1;
    return -1;
  }
  final en = s.text.toLowerCase();
  if (en.startsWith(qLower)) return 0;
  if (en.split(' ').any((w) => w.startsWith(qLower))) return 1;
  if (en.contains(qLower)) return 2;
  if (s.trans?.contains(qRaw) ?? false) return 3;
  return -1;
}

List<Suggestion> _filter(List<Suggestion> src, String q) {
  final cjk = _hasCjk(q);
  final qLower = q.toLowerCase();
  final scored = <(int, Suggestion)>[];
  for (final s in src) {
    final r = _rank(s, qLower, q, cjk);
    if (r >= 0) scored.add((r, s));
  }
  scored.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    return b.$2.count.compareTo(a.$2.count); // 同档按热度
  });
  return [for (final e in scored) e.$2];
}

/// 主查询:按四类分别过滤排序。alphabetical=true 时标签改按字母序。
SuggestResult querySuggestions(String query, {bool alphabetical = false}) {
  final q = query.trim();
  if (q.isEmpty) return const SuggestResult();
  var tags = _filter(_tags, q);
  if (alphabetical) {
    tags = [...tags]..sort((a, b) => a.text.compareTo(b.text));
  }
  return SuggestResult(
    characters: _filter(_characters, q),
    ocs: _filter(_ocs, q),
    works: _filter(_works, q),
    tags: tags,
  );
}

/// 补全行要显示的中文:优先用结果自带的译名,缺则反查缓存
/// (离线词库全量 + wiki/共享库/LLM 的网络回填)。
///
/// D 站来的行只有 `/api/tags/wiki` 那一路译名,wiki 没写中文别名就一直空着 ——
/// 而同一个标签在离线词库里往往是有中文的,只是没人去查。
/// 反查还捡到 [TagTranslationService] 后来补上的那批:那是异步到货的,
/// 结果快照里不可能有,只能显示时现查。
String? transOf(Suggestion s) {
  final t = s.trans;
  if (t != null && t.isNotEmpty) return t;
  return switch (s.kind) {
    // 画师串 / OC 是本地库实体,名字不是 Danbooru 标签,反查只会串味
    SuggestionKind.artist || SuggestionKind.oc => null,
    _ => translationOf(s.text),
  };
}

/// 供注音流反查某个已确定标签的中文翻译(先查网络回填缓存,再退回内置词库)
String? translationOf(String text) {
  final t = text.trim().toLowerCase();
  final cached = _transCache[t];
  if (cached != null) return cached;
  for (final s in _tags) {
    if (s.text.toLowerCase() == t) return s.trans;
  }
  for (final s in _characters) {
    if (s.text.toLowerCase() == t) return s.trans;
  }
  return null;
}

/// 反查某标签热度(词条栏用),<1000 或未知返回 null
int? countOf(String text) {
  final t = text.trim().toLowerCase();
  final cached = _countCache[t];
  if (cached != null && cached >= 1000) return cached;
  for (final s in [..._tags, ..._characters]) {
    if (s.text.toLowerCase() == t) return s.count >= 1000 ? s.count : null;
  }
  return null;
}

/// 关联标签(占位:静态共现表;正式版接 tagRelated 服务)
const _related = <String, List<String>>{
  'moonlit rooftop': ['full moon', 'city lights', 'night'],
  'silver long hair': ['red eyes', 'hair between eyes', 'sidelocks'],
  'gothic dress': ['frills', 'lace trim', 'ribbon'],
  '1girl': ['solo', 'looking at viewer', 'cowboy shot'],
  'best quality': ['masterpiece', 'highly detailed', 'ultra-detailed'],
  'full moon': ['night sky', 'starry sky', 'cloud'],
  'red eyes': ['glowing eyes', 'slit pupils'],
};

List<String> relatedTags(String text) =>
    _related[text.trim().toLowerCase()] ?? const [];

/// 标签 Wiki 摘要(占位:静态表;正式版接 Danbooru wiki API)
const _wiki = <String, String>{
  'yukata': '日式夏季传统单层和服,窄袖束以 obi 腰带,常与 festival、fireworks、summer 共现。',
  'gothic dress': '哥特风连衣裙,多为黑色蕾丝、荷叶边与束身剪裁,常搭 choker 与十字架。',
  '1girl': '画面中恰有一名女性角色,Danbooru 最核心的人数标签之一。',
  'silver long hair': '银白色过肩长发,常与 red eyes、hair between eyes、sidelocks 搭配。',
  'full moon': '完整满月,多用于夜景 / 星空 / 屋顶等构图。',
};

/// 标签 Wiki 摘要(占位),未知返回 null
String? wikiSummary(String text) => _wiki[text.trim().toLowerCase()];

/// Danbooru wiki 外链(占位跳转用)
String danbooruWikiUrl(String text) =>
    'https://danbooru.donmai.us/wiki_pages/'
    '${text.trim().toLowerCase().replaceAll(' ', '_')}';
