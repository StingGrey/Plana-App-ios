import 'dart:convert';

import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import 'models.dart';

export 'models.dart' show GenProvider, isAnimaModel, providerOfModel;

/// 主页附属功能模块系统(对齐 web moduleConfig):
/// - 注册表定死可管理的模块,每个模块归属一个模型父类(provider,
///   定义在 models.dart),可带「组内按具体型号」的能力门槛(如角色参考仅 4.5);
/// - 用户配置只有「启用 + 每组顺序」;
/// - 主页可见 = 归属当前父类 + 已启用 + 当前型号支持,不满足的整卡不渲染,
///   面板发起的生成也不发其数据(工作区数据保留,条件恢复即回来);
/// - 图库快照按剥离后状态入库,「重新生成」忠实复现。
/// 新增模块 = 注册表加行(标 provider)+ 主页 `_moduleCard` 加卡。
enum GenModule { character, vibe, charRef, img2img, lora }

/// 注册表条目:图标与名称同主页卡片,管理页与卡片一眼对上。
class GenModuleDef {
  const GenModuleDef(
    this.key,
    this.icon,
    this.label, {
    this.provider = GenProvider.nai,
    this.supports,
  });

  final GenModule key;
  final IconData icon;
  final String label;
  final GenProvider provider;

  /// 组内按具体型号的能力门槛;null = 该组全部型号支持。
  final bool Function(String displayModel)? supports;

  bool supportsModel(String displayModel) =>
      supports?.call(displayModel) ?? true;
}

/// 新增模块 = 此处加一行 + 主页 `_moduleCard` 加一张卡。
const kGenModuleDefs = <GenModuleDef>[
  GenModuleDef(GenModule.character, Icons.group_outlined, '角色'),
  GenModuleDef(GenModule.vibe, Icons.palette_outlined, 'Vibe Transfer'),
  GenModuleDef(
    GenModule.charRef,
    Icons.face_retouching_natural,
    '角色参考',
    supports: crSupportsModel,
  ),
  GenModuleDef(GenModule.img2img, Icons.image_outlined, '图生图'),
  GenModuleDef(
    GenModule.lora,
    Icons.auto_awesome_outlined,
    'LoRA',
    provider: GenProvider.anima,
  ),
];

GenModuleDef genModuleDef(GenModule m) =>
    kGenModuleDefs.firstWhere((d) => d.key == m);

/// 各父类的默认顺序 = 注册表顺序。
const kDefaultOrderByProvider = <GenProvider, List<GenModule>>{
  GenProvider.nai: [
    GenModule.character,
    GenModule.vibe,
    GenModule.charRef,
    GenModule.img2img,
  ],
  GenProvider.anima: [GenModule.lora],
};

class GenModuleSettings {
  const GenModuleSettings({
    this.enabled = const {},
    this.order = kDefaultOrderByProvider,
  });

  /// 每模块启用位,缺省视为启用。
  final Map<GenModule, bool> enabled;

  /// 每个模型父类组内的模块顺序(含已隐藏的;隐藏只影响可见性,不丢位置)。
  final Map<GenProvider, List<GenModule>> order;

  bool isEnabled(GenModule m) => enabled[m] ?? true;

  List<GenModule> orderOf(GenProvider p) =>
      order[p] ?? kDefaultOrderByProvider[p] ?? const [];

  /// 统一可见性谓词:归属该模型的父类 + 已启用 + 该型号支持。
  /// 渲染、请求剥离、生成前提示全部走同一判定,不允许分叉。
  bool isVisibleFor(GenModule m, String displayModel) {
    final def = genModuleDef(m);
    return def.provider == providerOfModel(displayModel) &&
        isEnabled(m) &&
        def.supportsModel(displayModel);
  }

  /// 主页可见序列。
  List<GenModule> visibleFor(String displayModel) => [
    for (final m in orderOf(providerOfModel(displayModel)))
      if (isVisibleFor(m, displayModel)) m,
  ];

  GenModuleSettings copyWith({
    Map<GenModule, bool>? enabled,
    Map<GenProvider, List<GenModule>>? order,
  }) => GenModuleSettings(
    enabled: enabled ?? this.enabled,
    order: order ?? this.order,
  );

  /// 容错读取:以默认为骨架 —— 每组过滤不属于该组/未知的项、去重,
  /// 新增模块补到组尾;旧版扁平 order(数组)直接归入 nai 组。
  factory GenModuleSettings.fromJson(Map<String, dynamic> j) {
    final byName = {for (final m in GenModule.values) m.name: m};
    final enabled = <GenModule, bool>{};
    final je = j['enabled'];
    if (je is Map) {
      for (final e in je.entries) {
        final m = byName[e.key];
        final v = e.value;
        if (m != null && v is bool) enabled[m] = v;
      }
    }

    List<GenModule> repair(GenProvider p, Object? raw) {
      final out = <GenModule>[];
      if (raw is List) {
        for (final name in raw) {
          final m = byName[name];
          if (m != null && genModuleDef(m).provider == p && !out.contains(m)) {
            out.add(m);
          }
        }
      }
      for (final m in kDefaultOrderByProvider[p] ?? const <GenModule>[]) {
        if (!out.contains(m)) out.add(m);
      }
      return out;
    }

    final jo = j['order'];
    final order = <GenProvider, List<GenModule>>{
      for (final p in GenProvider.values)
        p: repair(
          p,
          jo is Map
              ? jo[p.name]
              // 旧版扁平数组:全部归入 nai 组
              : (p == GenProvider.nai && jo is List ? jo : null),
        ),
    };
    return GenModuleSettings(enabled: enabled, order: order);
  }

  Map<String, dynamic> toJson() => {
    'enabled': {for (final e in enabled.entries) e.key.name: e.value},
    'order': {
      for (final e in order.entries)
        e.key.name: [for (final m in e.value) m.name],
    },
  };
}

/// 面板发起的生成前调用:清掉当前不可见模块的数据(隐藏、型号不支持、
/// 或不属当前模型父类 —— 如 anima 下的全部 NAI 模块;只影响本次快照,
/// 不动工作区)。入库的即此剥离后快照,「重新生成」不再受当时的模块配置影响。
GenerateState stripHiddenModules(GenerateState s, GenModuleSettings ms) {
  final model = s.params.model;
  bool on(GenModule m) => ms.isVisibleFor(m, model);
  var out = s;
  if (!on(GenModule.character) && out.characters.isNotEmpty) {
    out = out.copyWith(characters: const []);
  }
  if (!on(GenModule.vibe) && out.vibes.isNotEmpty) {
    out = out.copyWith(vibes: const []);
  }
  if (!on(GenModule.charRef) && out.charRefs.isNotEmpty) {
    out = out.copyWith(charRefs: const []);
  }
  if (!on(GenModule.img2img) && out.img2img != null) {
    out = out.copyWith(img2img: null);
  }
  if (!on(GenModule.lora) && out.loras.isNotEmpty) {
    out = out.copyWith(loras: const []);
  }
  return out;
}

const _key = 'gen_modules';

final genModulesProvider =
    AsyncNotifierProvider<GenModulesNotifier, GenModuleSettings>(
      GenModulesNotifier.new,
    );

class GenModulesNotifier extends AsyncNotifier<GenModuleSettings> {
  @override
  Future<GenModuleSettings> build() async {
    try {
      final raw = await ref.read(prefsStoreProvider).read(key: _key);
      if (raw == null || raw.isEmpty) return const GenModuleSettings();
      return GenModuleSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return const GenModuleSettings();
    }
  }

  /// 先改状态(立即生效),再尽力持久化。
  Future<void> patch(
    GenModuleSettings Function(GenModuleSettings) change,
  ) async {
    final next = change(state.value ?? const GenModuleSettings());
    state = AsyncData(next);
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _key, value: jsonEncode(next.toJson()));
    } catch (_) {}
  }
}
