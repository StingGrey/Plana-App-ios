import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart' show isNai5Model;

/// 提示词预设:生成时拼进正/负提示词,不占用输入框。
/// 对齐 web `utils/storage.ts` 的 PromptPresetData + LeftSidebar 预设弹窗:
/// 五档内置(legacy 两档 + V5 两档 + 无,不可改删)+ 自定义(可增删改),
/// 激活项全局唯一;内置档按 [PromptPreset.scope] 只在对应模型系列下出现。
class PromptPreset {
  const PromptPreset({
    required this.id,
    required this.name,
    required this.positive,
    required this.negative,
    this.isDefault = false,
    this.createdAt,
    this.scope,
    this.suffixPositive = false,
  });

  final String id;
  final String name;
  final String positive;
  final String negative;
  final bool isDefault;
  final int? createdAt;

  /// 适用模型系列:`'v5'` 只在 V5 下出现,`'legacy'` 只在 V4.5 及更早出现。
  /// null(自定义预设)= 不限系列,两边都能选。
  ///
  /// 分组的原因:V5 的官方质量词/负面档与 V4.5 完全是两套文本(V5 还多一个
  /// 「轻度」正面档),混在一个列表里选会串味。
  final String? scope;

  /// 正面预设拼在提示词**末尾**而不是开头。
  ///
  /// 官方从 V4 起就把质量词放末尾(负面一律前缀),但老的 heavy/light 在我们这儿
  /// 一直是前缀 —— 改了会让存量用户出图风格突变,所以只有新增的 V5 档标 true。
  final bool suffixPositive;

  PromptPreset copyWith({String? name, String? positive, String? negative}) =>
      PromptPreset(
        id: id,
        name: name ?? this.name,
        positive: positive ?? this.positive,
        negative: negative ?? this.negative,
        isDefault: isDefault,
        createdAt: createdAt,
        scope: scope,
        suffixPositive: suffixPositive,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'positive': positive,
    'negative': negative,
    if (createdAt != null) 'createdAt': createdAt,
    if (scope != null) 'scope': scope,
    if (suffixPositive) 'positivePlacement': 'suffix',
  };

  factory PromptPreset.fromJson(Map<String, dynamic> j) => PromptPreset(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '未命名',
    positive: (j['positive'] as String?) ?? '',
    negative: (j['negative'] as String?) ?? '',
    createdAt: (j['createdAt'] as num?)?.toInt(),
    scope: j['scope'] as String?,
    suffixPositive: j['positivePlacement'] == 'suffix',
  );
}

/// 内置五档,文本与 web `DEFAULT_PROMPT_PRESETS` 逐字一致(勿"修正"其中的
/// 重复词、少一个空格的 `absurdres,very aesthetic` —— 契约以 web 为准)。
///
/// 按系列分成两组:legacy 组是 V4.5 及更早的历史文本(**勿动**,存量用户的出图
/// 风格挂在上面),v5 组逐字对齐官方 Quality Preset + Undesired Content Preset。
const kDefaultPromptPresets = <PromptPreset>[
  // ===== V4.5 及更早 =====
  PromptPreset(
    id: 'heavy',
    name: 'Heavy (重度)',
    scope: 'legacy',
    positive:
        'best quality, amazing quality, very aesthetic, absurdres,very aesthetic, masterpiece, no text',
    negative:
        'lowres, artistic error, film grain, scan artifacts, worst quality, bad quality, jpeg artifacts, very displeasing, chromatic aberration, dithering, halftone, screentone, multiple views, logo, too many watermarks, negative space, blank page',
    isDefault: true,
  ),
  PromptPreset(
    id: 'light',
    name: 'Light (轻度)',
    scope: 'legacy',
    positive: 'very aesthetic, masterpiece, no text',
    negative:
        'lowres, artistic error, scan artifacts, worst quality, bad quality, jpeg artifacts, multiple views, very displeasing, too many watermarks, negative space, blank page',
    isDefault: true,
  ),
  // ===== V5 =====
  // 官方 V5 把老的「质量标签开关」(布尔)换成了三档下拉 standard/light/none,
  // 且 Full 与 Curated 共用同一张表(不像 4.5 Curated 会额外塞 rating:general)。
  // 我们把「正面质量档」和「负面档」并成一条预设,配对沿用官方默认:
  //   标准 = quality standard + uc heavy    轻度 = quality light + uc light
  PromptPreset(
    id: 'v5-standard',
    name: 'Standard (标准)',
    scope: 'v5',
    suffixPositive: true,
    positive: 'very aesthetic, masterpiece, no text',
    negative:
        'lowres, artistic error, film grain, scan artifacts, worst quality, bad quality, jpeg artifacts, very displeasing, chromatic aberration, dithering, halftone, screentone, multiple views, logo, too many watermarks, negative space, blank page',
    isDefault: true,
  ),
  PromptPreset(
    id: 'v5-light',
    name: 'Light (轻度)',
    scope: 'v5',
    suffixPositive: true,
    // V5 新增的正面档;负面 light 也和 4.5 不同,多了 0::ai-generated:: 这种零权重写法
    positive: 'very aesthetic, amazing quality, no text',
    negative:
        'lowres, bad hands, bad anatomy, artistic error, sepia, white haze, worst quality, very displeasing, jpeg artifacts, 0::ai-generated::',
    isDefault: true,
  ),
  PromptPreset(
    id: 'none',
    name: 'None (无)',
    positive: '',
    negative: '',
    isDefault: true,
  ),
];

class PromptPresetsState {
  const PromptPresetsState({required this.presets, required this.activeId});

  final List<PromptPreset> presets;
  final String activeId;

  PromptPreset? get active {
    for (final p in presets) {
      if (p.id == activeId) return p;
    }
    return null;
  }
}

final promptPresetsProvider =
    AsyncNotifierProvider<PromptPresetsNotifier, PromptPresetsState>(
      PromptPresetsNotifier.new,
    );

/// 持久化:support 目录 `prompt_presets.json`,只存自定义预设 + 激活 id
/// (默认预设恒用内置文本,web 同款——localStorage 里的默认项每次加载都被覆盖)。
class PromptPresetsNotifier extends AsyncNotifier<PromptPresetsState> {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/prompt_presets.json');
  }

  @override
  Future<PromptPresetsState> build() async {
    var activeId = 'heavy'; // web getActivePresetId 默认档
    var custom = const <PromptPreset>[];
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        activeId = (j['activeId'] as String?) ?? 'heavy';
        custom = [
          for (final e in (j['custom'] as List? ?? const []))
            PromptPreset.fromJson(e as Map<String, dynamic>),
        ];
      }
    } catch (_) {} // 损坏按初始状态处理
    final presets = [...kDefaultPromptPresets, ...custom];
    if (!presets.any((p) => p.id == activeId)) activeId = 'heavy';
    return PromptPresetsState(presets: presets, activeId: activeId);
  }

  Future<void> _write(PromptPresetsState s) async {
    state = AsyncData(s);
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          'activeId': s.activeId,
          'custom': [
            for (final p in s.presets)
              if (!p.isDefault) p.toJson(),
          ],
        }),
      );
    } catch (_) {} // 写失败只影响下次启动的恢复,忽略
  }

  Future<void> setActive(String id) async {
    final s = await future;
    if (s.activeId == id || !s.presets.any((p) => p.id == id)) return;
    await _write(PromptPresetsState(presets: s.presets, activeId: id));
  }

  Future<void> add({
    required String name,
    String positive = '',
    String negative = '',
  }) async {
    final s = await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final p = PromptPreset(
      id: 'custom_$now', // web addPromptPreset 同款 id 形态
      name: name,
      positive: positive,
      negative: negative,
      createdAt: now,
    );
    await _write(
      PromptPresetsState(presets: [...s.presets, p], activeId: s.activeId),
    );
  }

  /// 仅自定义可改;默认预设恒内置文本(web 同款)。
  Future<void> updatePreset(
    String id, {
    String? name,
    String? positive,
    String? negative,
  }) async {
    final s = await future;
    final presets = [
      for (final p in s.presets)
        if (p.id == id && !p.isDefault)
          p.copyWith(name: name, positive: positive, negative: negative)
        else
          p,
    ];
    await _write(PromptPresetsState(presets: presets, activeId: s.activeId));
  }

  /// 仅自定义可删;删除激活中的回落到「无」(web handleDeletePreset 同款)。
  Future<void> remove(String id) async {
    final s = await future;
    if (s.presets.any((p) => p.id == id && p.isDefault)) return;
    await _write(
      PromptPresetsState(
        presets: [...s.presets.where((p) => p.id != id)],
        activeId: s.activeId == id ? 'none' : s.activeId,
      ),
    );
  }

  /// 批量导入(web 备份迁移用):**按 id upsert** —— 与 web `restoreBackup` 的
  /// 「相同 ID 覆盖、其余保留」同语义,重复导入同一份备份是幂等的。
  /// 沿用来源 id 而非 [add] 那样新发 —— 后者按毫秒发号,一次导入多条会撞 id。
  /// 内置三档的 id 一律跳过(app 侧恒用内置文本)。返回写入条数。
  /// [activeId] 命中已有预设时顺带切过去,命中不了就不动当前激活项。
  Future<int> importPresets(
    List<PromptPreset> incoming, {
    String? activeId,
  }) async {
    final s = await future;
    final byId = {for (final p in s.presets) p.id: p};
    var n = 0;
    for (final p in incoming) {
      if (kDefaultPromptPresets.any((d) => d.id == p.id)) continue;
      byId[p.id] = p;
      n++;
    }
    final merged = [
      ...kDefaultPromptPresets,
      for (final p in byId.values)
        if (!p.isDefault) p,
    ];
    final active = activeId != null && merged.any((p) => p.id == activeId)
        ? activeId
        : s.activeId;
    if (n == 0 && active == s.activeId) return 0;
    await _write(PromptPresetsState(presets: merged, activeId: active));
    return n;
  }
}

/// 逗号拼接(web:`${a}, ${b}`);任一侧为空则不留悬空逗号。
String joinPromptParts(String a, String b) {
  final x = a.trim();
  if (x.isEmpty) return b;
  if (b.trim().isEmpty) return x;
  return '$x, $b';
}

/// 把预设拼进提示词。正面按 [PromptPreset.suffixPositive] 决定前/后缀,
/// 负面一律前缀(同官方)。
({String positive, String negative}) applyPromptPreset(
  PromptPreset? p,
  String positive,
  String negative,
) {
  if (p == null) return (positive: positive, negative: negative);
  return (
    positive: p.positive.isEmpty
        ? positive
        : p.suffixPositive
        ? joinPromptParts(positive, p.positive)
        : joinPromptParts(p.positive, positive),
    negative: p.negative.isEmpty
        ? negative
        : joinPromptParts(p.negative, negative),
  );
}

/// 内置档是否带正面质量词(= `qualityToggle` 的取值)。
/// 自定义预设不在这张表里,恒 false —— 拿得到预设对象的调用方应直接看
/// `preset.positive.isNotEmpty`,这个函数只是给拿不到对象的地方兜底。
bool builtinPresetHasPositive(String id) =>
    kDefaultPromptPresets.any((p) => p.id == id && p.positive.isNotEmpty);

// ==================== 预设 × 模型系列 ====================

/// 当前模型能看到哪些档:内置档按 [PromptPreset.scope] 过滤,
/// 自定义预设(无 scope)两边都留。
List<PromptPreset> promptPresetsForModel(
  List<PromptPreset> presets,
  String displayModel,
) {
  final want = isNai5Model(displayModel) ? 'v5' : 'legacy';
  return [
    for (final p in presets)
      if (p.scope == null || p.scope == want) p,
  ];
}

/// 同强度档在两个系列之间的对应;没列出的(自定义预设)不参与映射。
const _presetEquivalents = <String, String>{
  'heavy': 'v5-standard',
  'light': 'v5-light',
  'v5-standard': 'heavy',
  'v5-light': 'light',
};

/// 把当前档映射到目标模型可用的档(同官方:切模型会重算质量档)。
/// 仍然可选 → 原样保留;能对上同强度档 → 换过去;都不行 → 落到列表首项。
String remapPromptPresetId(
  String activeId,
  List<PromptPreset> presets,
  String displayModel,
) {
  final visible = promptPresetsForModel(presets, displayModel);
  if (visible.any((p) => p.id == activeId)) return activeId;
  final eq = _presetEquivalents[activeId];
  if (eq != null && visible.any((p) => p.id == eq)) return eq;
  return visible.isEmpty ? 'none' : visible.first.id;
}

// ==================== 档位提示(tag_hint) ====================

/// 官方 `tag_hint_qt` / `tag_hint_uc_preset` 共用的数字表。
/// ⚠ 它和发送时那个 `ucPreset` 数字**不是**一张表 —— 后者是档位数组的下标,
/// 这张是官方内部的档位枚举顺序。两者恰好都有 heavy/light,别看串了。
const _officialPresetHintOrder = <String>[
  'none',
  'standard',
  'heavy',
  'light',
  'humanFocus',
  'furryFocus',
  'lowQualityPlusBadAnatomy',
  'lowQuality',
  'badAnatomy',
];

/// 每条内置预设的文本实际取自哪个官方档。
///
/// 官方导入图片时拿这个提示决定「先拿哪个档去试着把预设文本剥掉」,剥不掉会
/// 自己暴力扫描兜底 —— 所以对不上就留空(= none),别硬凑一个看着像的。
/// heavy 的正面是 V3 + V4.5 两段官方文本拼出来的,不对应任何单一官方档,只报负面档。
const _presetOfficialSource = <String, ({String? quality, String? uc})>{
  'heavy': (quality: null, uc: 'heavy'),
  'light': (quality: 'standard', uc: 'light'),
  'v5-standard': (quality: 'standard', uc: 'heavy'),
  'v5-light': (quality: 'light', uc: 'light'),
  'none': (quality: null, uc: null),
};

int _hintNum(String? name) {
  if (name == null) return 0;
  final i = _officialPresetHintOrder.indexOf(name);
  return i < 0 ? 0 : i;
}

/// 随生成一起发出的档位提示;自定义预设 / 未知 id 一律 none(0)。
({int qt, int ucPreset}) promptPresetTagHints(String presetId) {
  final src = _presetOfficialSource[presetId];
  return (qt: _hintNum(src?.quality), ucPreset: _hintNum(src?.uc));
}

/// 两个提示数字 → 可能的预设 id(同一对官方档在两个系列各有一条)。
Set<String> _presetIdsFromTagHints(int? qt, int? ucPreset) {
  if (qt == null && ucPreset == null) return const {};
  String name(int? n) =>
      n == null || n < 0 || n >= _officialPresetHintOrder.length
      ? 'none'
      : _officialPresetHintOrder[n];
  final wantQuality = name(qt);
  final wantUc = name(ucPreset);
  return {
    for (final e in _presetOfficialSource.entries)
      if ((e.value.quality ?? 'none') == wantQuality &&
          (e.value.uc ?? 'none') == wantUc)
        e.key,
  };
}

// ==================== 导入时的预设识别 ====================
//
// 出图时预设文本是拼进提示词一起发的,所以图片元数据里的提示词是「预设 + 用户原文」。
// 导入若原样填回输入框,当前预设会在下次生成时**再拼一遍** —— 这才是这套识别的正题,
// 认出档位只是顺带。因此:**认不出就必须把档位切到「无」**,宁可少认也不能重复拼。
//
// 判据只有一条:能不能把某个预设的文本从提示词里**干净剥掉**。
// 元数据里的 tag_hint 只决定「先试哪个」,不作为结论 —— 同官方做法,省掉一堆特例分支。

/// 按 `,` / `,` 切成 tag 列表并去空白;空段丢弃。
List<String> _splitTags(String text) => [
  for (final t in text.split(RegExp('[,，]')))
    if (t.trim().isNotEmpty) t.trim(),
];

/// 从 tag 列表的头部或尾部剥掉 needle 序列;对不上返回 null。
///
/// 按 tag 比而不是按字符串前缀比:我们自己的内置档里就有 `absurdres,very aesthetic`
/// 这种少一个空格的写法,字符串匹配一碰格式化就废。
List<String>? _stripTagRun(
  List<String> tags,
  List<String> needle, {
  required bool suffix,
}) {
  if (needle.isEmpty) return tags;
  if (needle.length > tags.length) return null;
  final seg = suffix
      ? tags.sublist(tags.length - needle.length)
      : tags.sublist(0, needle.length);
  for (var i = 0; i < needle.length; i++) {
    if (seg[i].toLowerCase() != needle[i].toLowerCase()) return null;
  }
  return suffix
      ? tags.sublist(0, tags.length - needle.length)
      : tags.sublist(needle.length);
}

/// 认出这张图用的是哪条预设,并把预设文本从提示词里剥回去。
///
/// 命中条件(严,宁可漏不可错 —— 错认等于静默删掉用户自己写的词):
/// - **正负两边都要剥得掉**。我们的预设正负成对,这一条几乎把误判清零:用户手打
///   一个 `masterpiece` 不会命中,因为负面那十几个词不可能同时凑齐。
///   单边为空的预设退化成只验另一边。
/// - 认位置:前缀档从头剥,后缀档从尾剥。这不只是精确性 —— 4.5 的 Light 和 V5 的
///   Standard **正面文本完全相同**,只有位置能区分。
/// - 候选按 tag 总数倒序:长档先试,免得短档把长档的一部分先啃掉。
///
/// [hintQt] / [hintUcPreset] 是元数据里的档位提示,只用来把候选排到队首。
({PromptPreset preset, String positive, String negative})? detectPromptPreset(
  List<PromptPreset> presets,
  String positive,
  String negative, {
  int? hintQt,
  int? hintUcPreset,
}) {
  final posTags = _splitTags(positive);
  final negTags = _splitTags(negative);
  final hinted = _presetIdsFromTagHints(hintQt, hintUcPreset);

  final candidates =
      [
        for (final p in presets)
          if (p.positive.isNotEmpty || p.negative.isNotEmpty)
            (
              preset: p,
              weight:
                  _splitTags(p.positive).length + _splitTags(p.negative).length,
            ),
      ]..sort((a, b) {
        final ha = hinted.contains(a.preset.id) ? 1 : 0;
        final hb = hinted.contains(b.preset.id) ? 1 : 0;
        return hb != ha ? hb - ha : b.weight - a.weight;
      });

  for (final c in candidates) {
    final wantPos = _splitTags(c.preset.positive);
    final wantNeg = _splitTags(c.preset.negative);
    final restPos = wantPos.isEmpty
        ? posTags
        : _stripTagRun(posTags, wantPos, suffix: c.preset.suffixPositive);
    if (restPos == null) continue;
    final restNeg = wantNeg.isEmpty
        ? negTags
        : _stripTagRun(negTags, wantNeg, suffix: false);
    if (restNeg == null) continue;
    return (
      preset: c.preset,
      positive: restPos.join(', '),
      negative: restNeg.join(', '),
    );
  }
  return null;
}

/// 表外档位落到的值(= none 在档位数组里的下标)。
const kUcPresetNone = 4;

/// ucPreset 数值 = **该模型档位数组的下标**;V4.5/V5 都是
/// `[heavy, light, furryFocus, humanFocus, none]`。
///
/// 直连与 bot 两条线共用这一张表(web novelai.ts UC_PRESET_MAP,2026-08-24 起
/// bot 线也换了过来)。**别再按线拆成两张** —— bot 线历史上那套自造的反向取值
/// (heavy→4 / none→0)就是这么跑偏的:web 改表时只有一张跟着改,app 这边
/// 两张都留着,于是「重度」被记成了「无」。
///
/// 表外(自定义预设)一律落 none:负面词是用户自己写的,不该再宣称套了官方档。
/// `v5-*` 是把「正面质量档 + 负面档」并成一条预设后的内置 id,取值跟随其官方负面档。
int ucPresetValue(String id) => switch (id) {
  'heavy' || 'v5-standard' => 0,
  'light' || 'v5-light' => 1,
  'furryFocus' => 2,
  'humanFocus' => 3,
  _ => kUcPresetNone,
};
