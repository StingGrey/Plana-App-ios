import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// 提示词预设:生成时作为前缀拼进正/负提示词,不占用输入框。
/// 对齐 web `utils/storage.ts` 的 PromptPresetData + LeftSidebar 预设弹窗:
/// 三档内置(重度/轻度/无,不可改删)+ 自定义(可增删改),激活项全局唯一。
class PromptPreset {
  const PromptPreset({
    required this.id,
    required this.name,
    required this.positive,
    required this.negative,
    this.isDefault = false,
    this.createdAt,
  });

  final String id;
  final String name;
  final String positive;
  final String negative;
  final bool isDefault;
  final int? createdAt;

  PromptPreset copyWith({String? name, String? positive, String? negative}) =>
      PromptPreset(
        id: id,
        name: name ?? this.name,
        positive: positive ?? this.positive,
        negative: negative ?? this.negative,
        isDefault: isDefault,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'positive': positive,
    'negative': negative,
    if (createdAt != null) 'createdAt': createdAt,
  };

  factory PromptPreset.fromJson(Map<String, dynamic> j) => PromptPreset(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '未命名',
    positive: (j['positive'] as String?) ?? '',
    negative: (j['negative'] as String?) ?? '',
    createdAt: (j['createdAt'] as num?)?.toInt(),
  );
}

/// 内置三档,文本与 web `DEFAULT_PROMPT_PRESETS` 逐字一致(勿"修正"其中的
/// 重复词/结尾 1 —— 契约以 web 为准)。
const kDefaultPromptPresets = <PromptPreset>[
  PromptPreset(
    id: 'heavy',
    name: '重度 (质量标签)',
    positive:
        'best quality, amazing quality, very aesthetic, absurdres,very aesthetic, masterpiece, no text',
    negative:
        'lowres, artistic error, film grain, scan artifacts, worst quality, bad quality, jpeg artifacts, very displeasing, chromatic aberration, dithering, halftone, screentone, multiple views, logo, too many watermarks, negative space, blank page, 1',
    isDefault: true,
  ),
  PromptPreset(
    id: 'light',
    name: '轻度',
    positive: 'very aesthetic, masterpiece, no text',
    negative:
        'lowres, artistic error, scan artifacts, worst quality, bad quality, jpeg artifacts, multiple views, very displeasing, too many watermarks, negative space, blank page, 1',
    isDefault: true,
  ),
  PromptPreset(
    id: 'none',
    name: '无',
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

/// 前缀拼接(web:`${preset}, ${prompt}`);任一侧为空则不留悬空逗号。
String joinPresetPrefix(String preset, String user) {
  final p = preset.trim();
  if (p.isEmpty) return user;
  if (user.trim().isEmpty) return p;
  return '$p, $user';
}

/// 直连线 ucPreset 数值(web novelai.ts UC_PRESET_MAP,自定义预设 → 4)。
int ucPresetDirect(String id) => switch (id) {
  'heavy' => 0,
  'light' => 1,
  _ => 4,
};

/// bot 线 ucPreset 数值(web generateImageViaBot 的 ucPresetMap,自定义 → 4)。
int ucPresetBot(String id) => switch (id) {
  'heavy' => 4,
  'light' => 3,
  'none' => 0,
  _ => 4,
};
