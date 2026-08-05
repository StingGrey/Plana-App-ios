import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/remote_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/image_ops.dart';
import '../../core/util/image_pick.dart';
import '../../core/util/prompt_convert.dart' show convertSdToNai;
import '../char_library/char_library.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart';
import '../generate/nai_request.dart' show naiModelId;
import '../generate/widgets/common.dart';
import '../lora/lora_install_queue.dart';
import '../shell/shell_state.dart';
import '../vibe_library/naiv4vibe_codec.dart' show kModelToEncodingKey;
import '../vibe_library/vibe_library.dart';
import 'image_metadata.dart';
import 'import_category.dart';
import 'metadata_detail_page.dart';
import '../../core/util/haptics.dart';

/// 后台 isolate 算图片内容哈希。
String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

/// metadata sampler API id → 本机展示名(对齐 models.dart `samplers`)。
const _samplerIdToDisplay = <String, String>{
  'k_euler_ancestral': 'Euler Ancestral',
  'k_euler': 'Euler',
  'k_dpmpp_2s_ancestral': 'DPM++ 2S A',
  'k_dpmpp_2m_sde': 'DPM++ 2M SDE',
  'k_dpmpp_2m': 'DPM++ 2M',
  'k_dpmpp_sde': 'DPM++ SDE',
};

bool _samplerSupported(String? id) =>
    id != null && _samplerIdToDisplay.containsKey(id);
bool _noiseSupported(String? n) => n != null && noiseSchedules.contains(n);

/// 来源名 → 本机模型展示名(v3 无对应,返回 null 保持当前不变;对齐 web 移动端)。
String? _modelFromSource(String source) {
  final s = source.toLowerCase();
  if (s.contains('v4.5 curated')) return 'NAI 4.5 Curated';
  if (s.contains('v4.5')) return 'NAI 4.5 Full';
  if (s.contains('v4 curated')) return 'NAI 4.0 Curated';
  if (s.contains('v4')) return 'NAI 4.0 Full';
  return null;
}

Uint8List? _tryB64(String s) {
  try {
    return base64.decode(s);
  } catch (_) {
    return null;
  }
}

/// 元数据角色 centers(0~1 坐标)→ 站位格('A1'..'E5';无坐标返回 null=AUTO)。
/// 正向映射是 x=(col+.5)/5、y=(row-.5)/5,这里取反并就近取整 ——
/// 网格出身的坐标可精确还原,个别手写的奇异坐标吸附到最近格。
String? gridPosOfCenter(double? x, double? y) {
  if (x == null || y == null) return null;
  final col = (x * 5 - 0.5).round().clamp(0, 4);
  final row = (y * 5 + 0.5).round().clamp(1, 5);
  return '${'ABCDE'[col]}$row';
}

/// 创作页吸底栏「导入图片」入口:选图 → 推入全屏导入面板。
Future<void> openImportPanel(BuildContext context) async {
  final file = await pickImageFile(context);
  if (file == null || !context.mounted) return;
  unawaited(
    Navigator.of(context).push(
      sharedAxisRoute(
        ImportImagePanel(
          bytes: file.bytes,
          fileName: file.name,
          displayName: file.baseName,
        ),
      ),
    ),
  );
}

/// 导入图片面板(全屏)。3a 导入主页:解析元数据、逐项勾选导入到生成页,
/// 或把整张图「用作」图生图 / 风格 / 角色参考 / 反推。无元数据时退化为纯「用作」。
class ImportImagePanel extends ConsumerStatefulWidget {
  const ImportImagePanel({
    super.key,
    required this.bytes,
    required this.fileName,
    required this.displayName,
  });

  final Uint8List bytes;
  final String fileName;
  final String displayName;

  @override
  ConsumerState<ImportImagePanel> createState() => _ImportImagePanelState();
}

class _ImportImagePanelState extends ConsumerState<ImportImagePanel> {
  bool _loading = true;
  ImageMetadata? _meta;

  /// 导入目标的模型类别(= 当前出图模型的类别,面板内可切换)。
  /// null 表示还没读到(build 时按当前模型补上)。
  ModelCategory? _target;

  // 提示词
  bool _usePrompt = false;
  bool _useNegative = false;

  /// 把 a1111 权重语法转成 NAI 方言。只在「源是 a1111、目标是 NovelAI」时有意义。
  bool _convertPrompt = true;

  // 角色
  final Set<int> _charChecked = {};
  bool _charExpanded = true;
  bool _charAppend = false; // false=完全覆盖,true=额外添加

  // Vibe
  final Set<int> _vibeChecked = {};
  List<Uint8List?> _vibeBytes = const [];
  bool _vibeExpanded = true;
  bool _vibeAppend = false;

  // 生成设置
  bool _settingsExpanded = true;
  bool _useModel = false;
  bool _useRes = false;
  bool _useSteps = false;
  bool _useCfg = false;
  bool _useCfgRescale = false;
  bool _useVariety = false;
  bool _useSampler = false;
  bool _useScheduler = false;
  bool _useSeed = false;

  // AI 反推结果模式:非空时面板只显示一条正向提示词(内容=反推标签)。
  String? _reverseTags;
  bool _useReverse = true;

  /// 已展开全文的提示词行(按标题键)。默认全收起 —— 面板要先让人一眼看全
  /// 有哪些可导入项,长提示词铺开会把下面的角色/Vibe/参数全顶出屏幕。
  final _expandedRows = <String>{};

  /// 图片体积文案(顶卡与详情页共用)。
  String get _sizeText {
    final b = widget.bytes.length;
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '$b B';
  }

  @override
  void initState() {
    super.initState();
    _parse();
  }

  Future<void> _parse() async {
    final m = await extractImageMetadata(widget.bytes);
    if (!mounted) return;
    setState(() {
      _meta = m;
      _loading = false;
      _target ??= categoryOfModel(ref.read(generateProvider).params.model);
      if (m != null) _initSelections(m);
    });
    if (m != null && m.loras.isNotEmpty) unawaited(_resolveLoras(m));
  }

  // ---- LoRA 认领(元数据 → 本地库 / Civitai / 找不到) ----

  /// 认领结果,与 `_meta!.loras` 同下标一一对应。
  List<LoraResolveResult?> _loraHits = const [];
  bool _resolvingLoras = false;

  /// LoRA 区展开态(与 Vibe/生成设置同款折叠)。
  bool _loraExpanded = true;

  /// 完全覆盖(换成这一份)/ 额外添加(并进已挂的)。语义同角色、Vibe。
  bool _loraAppend = false;

  /// 勾了要挂载的行下标。库里有的和 Civitai 上有的默认都勾上(可取消)。
  final _loraChecked = <int>{};

  Future<void> _resolveLoras(ImageMetadata m) async {
    setState(() {
      _resolvingLoras = true;
      _loraHits = List.filled(m.loras.length, null);
    });
    try {
      final hits = await ref
          .read(backendClientProvider)
          .resolveLoras(
            sessionId: (await ref.read(botSessionProvider.future))?.sessionId,
            items: [
              for (final l in m.loras)
                (
                  name: l.name,
                  hash: l.hash ?? '',
                  weight: l.weight,
                  clipWeight: l.clipWeight,
                ),
            ],
          );
      if (!mounted) return;
      setState(() {
        _loraHits = [
          for (var i = 0; i < m.loras.length; i++)
            i < hits.length ? hits[i] : null,
        ];
        // 认领到的默认勾上 —— 点「导入」就是要这一份。
        // Civitai 上有的一并勾:导入后先占位挂着、后台下载,不在这页做决策。
        _loraChecked
          ..clear()
          ..addAll([
            for (var i = 0; i < _loraHits.length; i++)
              if (_loraHits[i]?.isLocal == true ||
                  _loraHits[i]?.isCivitai == true)
                i,
          ]);
      });
    } catch (_) {
      // 认领失败不影响其它导入项,LoRA 区退回纯展示
    } finally {
      if (mounted) setState(() => _resolvingLoras = false);
    }
  }

  /// 认领结果 → 可挂载条目。权重/CLIP 权重按元数据带回;触发词已经在导入的
  /// 提示词里了,不再重复拼(挂载项只带库里的全量清单供 UI 勾选)。
  ActiveLora _activeLoraOf(LoraResolveResult h) => ActiveLora(
    name: h.item!.name,
    displayName: h.item!.displayName,
    weight: h.weight ?? h.item!.recommendedWeight,
    clipWeight: h.clipWeight,
    hasTe: h.item!.hasTe,
    triggerWords: h.item!.triggerWords,
    previewUrl: h.item!.previewUrl,
    type: h.item!.type,
  );

  /// 机房还没有的:入队后台下载 + 生成一条占位条目先挂上。
  /// 导入这一步不再问「要不要下载」——用户导的就是这张图的那份配置。
  /// 机房直拉慢则数分钟,队列跑在 provider 上,退出本页也继续;装好后就地转正。
  ActiveLora? _pendingLoraOf(LoraResolveResult h) {
    final vid = h.civitaiVersionId;
    if (vid == null) return null;
    final label = h.civitaiName.isNotEmpty ? h.civitaiName : h.name;
    ref
        .read(loraInstallQueueProvider.notifier)
        .enqueue(
          versionId: vid,
          name: label,
          weight: h.weight,
          clipWeight: h.clipWeight,
        );
    return ActiveLora(
      name: pendingLoraKey(vid),
      displayName: label,
      weight: h.weight ?? h.civitaiRecommendedWeight,
      clipWeight: h.clipWeight,
      triggerWords: h.civitaiTriggerWords,
      previewUrl: h.civitaiPreviewUrl,
      type: h.civitaiType,
      pending: LoraPending(versionId: vid),
    );
  }

  // ---- 类别路由 ----

  ModelCategory get _targetCategory =>
      _target ?? categoryOfModel(ref.read(generateProvider).params.model);

  ModelCategory? get _imageCategory => categoryOfImage(_meta);

  /// 跨类别(含「图没有对应的本机模型」,如 SD/A1111):只放行提示词。
  bool get _crossCategory => isCrossCategory(_meta, _targetCategory);

  bool get _inNai => !_crossCategory && _imageCategory == ModelCategory.nai;
  bool get _inComfy => !_crossCategory && _imageCategory == ModelCategory.comfy;

  /// 只在「源是 a1111 语法、目标是 NovelAI」时给转换开关,别的情况转了也白转。
  bool get _showConvert => needsPromptConversion(_meta, _targetCategory);

  /// Anima 走服务端 Modal 后端,只有 Bot 授权登录能用;切不过去就别给按钮。
  bool get _canSwitchCategory =>
      _imageCategory == ModelCategory.nai ||
      (_imageCategory == ModelCategory.comfy &&
          ref.read(authModeProvider).value == AuthMode.bot);

  void _initSelections(ImageMetadata m) {
    _usePrompt = m.prompt.isNotEmpty;
    _useNegative = m.negativePrompt.isNotEmpty;
    _convertPrompt = needsPromptConversion(m, _targetCategory);
    _charChecked.clear();
    _vibeChecked.clear();
    _vibeBytes = const [];
    if (_inNai) {
      _charChecked.addAll([for (var i = 0; i < m.characters.length; i++) i]);
      _vibeBytes = [
        for (final v in m.vibes) v.image != null ? _tryB64(v.image!) : null,
      ];
      _vibeChecked.addAll([
        for (var i = 0; i < m.vibes.length; i++)
          if (_vibeImportable(m, i)) i,
      ]);
    }
    // 超出本机支持面的单项不预勾(勾了也导不了,还让计数虚高)
    final specs = _settingItems;
    for (final e in specs) {
      e.set(e.unsupportedReason == null);
    }
    _useSeed = false; // 默认不导入种子(对齐定稿 4/5)
  }

  /// 切到图片所属的模型类别,切完面板就地重算出完整字段。
  void _switchCategory() {
    final target = _imageCategory;
    final m = _meta;
    if (target == null || m == null || !_canSwitchCategory) return;
    // 先把模型切过去:setModel 会套用该档推荐采样参数,必须发生在
    // _initSelections 之前,否则导入的具体数值会被档位默认值盖掉。
    final model = target == ModelCategory.comfy
        ? (animaModelFromSource(m.source) ?? animaModels.first)
        : (_modelFromSource(m.source) ?? models.first);
    ref.read(generateProvider.notifier).setModel(model);
    setState(() {
      _target = target;
      _initSelections(m);
    });
    hintSnack(
      context,
      '已切换到 ${categoryLabel(target)} 模型',
      icon: Icons.swap_horiz,
    );
  }

  // ---- Vibe 可导入性 ----

  /// 来源模型可识别时,元数据里编码串对应的 encodings 键(v4-5full 等)。
  /// vibe 编码是按模型算的,来源模型不明(V3 等)就没法归档,只能拒收。
  String? get _vibeEncKey {
    final display = _importModel;
    return display == null ? null : kModelToEncodingKey[naiModelId(display)];
  }

  /// 有原图 → 可导入(生成时按当前模型现场编码);
  /// 仅编码 → 来源模型可识别才可导入(挂到该模型的编码键下)。
  bool _vibeImportable(ImageMetadata m, int i) =>
      _vibeBytes[i] != null ||
      (m.vibes[i].encoding != null && _vibeEncKey != null);

  // ---- 生成设置可用性 ----

  /// 来源可映射到本机模型时的展示名(v3 等无对应返回 null)。
  String? get _importModel {
    final m = _meta;
    return (m != null && m.isNovelAI) ? _modelFromSource(m.source) : null;
  }

  bool get _hasModel => _importModel != null;
  bool get _hasRes => (_meta?.width ?? 0) > 0 && (_meta?.height ?? 0) > 0;
  bool get _hasSteps => _meta?.steps != null;
  bool get _hasCfg => _meta?.scale != null;
  bool get _hasCfgRescale => _meta?.cfgRescale != null;
  bool get _hasVariety => _meta?.varietyPlus != null;
  bool get _hasSampler => _meta?.sampler != null;
  bool get _hasScheduler => _meta?.noiseSchedule != null;
  bool get _hasSeed => (_meta?.seed ?? '').isNotEmpty;

  // ---- 生成设置清单(按类别分叉) ----

  /// 当前类别下可导入的生成设置字段。跨类别时为空 —— 那种情况只放行提示词。
  List<_SettingSpec> get _settingItems {
    final m = _meta;
    if (m == null || _crossCategory) return const [];
    return _inComfy ? _animaSettingItems(m) : _naiSettingItems(m);
  }

  List<_SettingSpec> _naiSettingItems(ImageMetadata m) => [
    if (_hasModel)
      _SettingSpec('模型', _importModel!, _useModel, (v) => _useModel = v),
    if (_hasRes)
      _SettingSpec(
        '分辨率',
        '${m.width}×${m.height}',
        _useRes,
        (v) => _useRes = v,
      ),
    if (_hasSteps)
      _SettingSpec('Steps', m.steps!, _useSteps, (v) => _useSteps = v),
    if (_hasCfg) _SettingSpec('CFG', m.scale!, _useCfg, (v) => _useCfg = v),
    if (_hasCfgRescale)
      _SettingSpec(
        'CFG Rescale',
        m.cfgRescale!,
        _useCfgRescale,
        (v) => _useCfgRescale = v,
      ),
    // 叫 Variety+ 而不是「多样性」:创作页高级设置里就是这个名字,
    // 两处对不上的话用户认不出导的是哪一项。
    if (_hasVariety)
      _SettingSpec(
        'Variety+',
        m.varietyPlus! ? '开' : '关',
        _useVariety,
        (v) => _useVariety = v,
      ),
    if (_hasSampler)
      _SettingSpec(
        'Sampler',
        _samplerIdToDisplay[m.sampler!] ?? m.sampler!,
        _useSampler,
        (v) => _useSampler = v,
      ),
    if (_hasScheduler)
      _SettingSpec(
        'Scheduler',
        m.noiseSchedule!,
        _useScheduler,
        (v) => _useScheduler = v,
      ),
    if (_hasSeed) _SettingSpec('Seed', m.seed, _useSeed, (v) => _useSeed = v),
  ];

  /// Anima(ComfyUI)类别的字段。只认我们前端真正支持的那一面:6 个采样器、
  /// 5 个调度器、步数 6–50、CFG 1.0–7.0、三个模型档位。超出的**单项禁用并写明原因**,
  /// 不静默钳到范围内 —— 悄悄改成一个用户没选的值,比明说导不了更坏。
  List<_SettingSpec> _animaSettingItems(ImageMetadata m) {
    final tier = animaModelFromSource(m.source);
    final steps = int.tryParse(m.steps ?? '');
    final cfg = double.tryParse(m.scale ?? '');
    return [
      if (m.source.isNotEmpty)
        _SettingSpec(
          '模型',
          tier ?? m.source,
          _useModel,
          (v) => _useModel = v,
          unsupportedReason: tier == null ? '不是 Anima 的模型' : null,
        ),
      if (_hasRes)
        _SettingSpec(
          '分辨率',
          '${m.width}×${m.height}',
          _useRes,
          (v) => _useRes = v,
        ),
      if (steps != null)
        _SettingSpec(
          'Steps',
          m.steps!,
          _useSteps,
          (v) => _useSteps = v,
          unsupportedReason: animaStepsSupported(steps)
              ? null
              : '支持 ${animaStepsRange.min}–${animaStepsRange.max}',
        ),
      if (cfg != null)
        _SettingSpec(
          'CFG',
          m.scale!,
          _useCfg,
          (v) => _useCfg = v,
          unsupportedReason: animaCfgSupported(cfg)
              ? null
              : '支持 ${animaCfgRange.min}–${animaCfgRange.max}',
        ),
      if (m.sampler != null)
        _SettingSpec(
          'Sampler',
          animaSamplerLabel(m.sampler) ?? m.sampler!,
          _useSampler,
          (v) => _useSampler = v,
          unsupportedReason: animaSamplerLabel(m.sampler) == null
              ? '不支持的采样器'
              : null,
        ),
      if (m.noiseSchedule != null)
        _SettingSpec(
          'Scheduler',
          animaSchedulerLabel(m.noiseSchedule) ?? m.noiseSchedule!,
          _useScheduler,
          (v) => _useScheduler = v,
          unsupportedReason: animaSchedulerLabel(m.noiseSchedule) == null
              ? '不支持的调度器'
              : null,
        ),
      if (_hasSeed) _SettingSpec('Seed', m.seed, _useSeed, (v) => _useSeed = v),
    ];
  }

  /// 含 UI 不支持的值(未知 sampler / noise)时,整个生成设置禁止导入。
  /// 只对 NovelAI 类别成立 —— Anima 侧是逐项禁用(见 [_animaSettingItems])。
  String? get _settingsUnsupportedReason {
    final m = _meta;
    if (m == null || !_inNai) return null;
    final issues = <String>[];
    if (m.noiseSchedule != null && !_noiseSupported(m.noiseSchedule)) {
      issues.add('noise schedule: ${m.noiseSchedule}');
    }
    if (m.sampler != null && !_samplerSupported(m.sampler)) {
      issues.add('sampler: ${m.sampler}');
    }
    return issues.isEmpty ? null : issues.join('、');
  }

  bool get _hasAnySelection {
    if (_usePrompt || _useNegative) return true;
    if (_charChecked.isNotEmpty) return true;
    if (_vibeChecked.isNotEmpty) return true;
    if (_settingsUnsupportedReason == null &&
        _settingItems.any((e) => e.on && e.unsupportedReason == null)) {
      return true;
    }
    return false;
  }

  // ---- 导入执行 ----
  void _import() {
    final m = _meta;
    if (m == null) return;
    final notifier = ref.read(generateProvider.notifier);
    final msgs = <String>[];

    // 提示词(替换)。需要时先把 a1111 权重语法转成 NAI 方言 ——
    // 编辑器里存的始终是 NAI 语法,发 Anima 时由服务端翻回 ComfyUI 语法。
    String prep(String s) =>
        _convertPrompt && _showConvert ? convertSdToNai(s) : s;
    String? pos, neg;
    if (_usePrompt && m.prompt.isNotEmpty) pos = prep(m.prompt);
    if (_useNegative && m.negativePrompt.isNotEmpty) {
      neg = prep(m.negativePrompt);
    }
    if (pos != null || neg != null) {
      notifier.setPrompts(positive: pos, negative: neg);
    }

    // 角色(站位跟着角色勾选一起走,不单独设开关)
    if (_inNai && _charChecked.isNotEmpty) {
      final idx = _charChecked.toList()..sort();
      final chars = [
        for (final i in idx)
          (
            positive: m.characters[i].prompt,
            negative: m.characters[i].uc ?? '',
            position: gridPosOfCenter(
              m.characters[i].centerX,
              m.characters[i].centerY,
            ),
          ),
      ];
      notifier.addCharactersFrom(chars, replace: !_charAppend);
    }

    // 生成设置(NAI 类别、无不支持值)
    if (_inNai && _settingsUnsupportedReason == null) {
      final applyRes = _useRes && _hasRes;
      notifier.applyImportedSettings(
        model: _useModel ? _importModel : null,
        width: applyRes ? m.width : null,
        height: applyRes ? m.height : null,
        steps: _useSteps && m.steps != null ? int.tryParse(m.steps!) : null,
        cfg: _useCfg && m.scale != null ? double.tryParse(m.scale!) : null,
        cfgRescale: _useCfgRescale && m.cfgRescale != null
            ? double.tryParse(m.cfgRescale!)
            : null,
        varietyPlus: _useVariety ? m.varietyPlus : null,
        sampler: _useSampler && m.sampler != null
            ? _samplerIdToDisplay[m.sampler!]
            : null,
        noiseSchedule: _useScheduler && m.noiseSchedule != null
            ? m.noiseSchedule
            : null,
        seed: _useSeed && m.seed.isNotEmpty ? m.seed : null,
      );
    }

    // 生成设置(Anima 类别)。白名单/范围校验在字段清单里做过(超出的项压根勾不上),
    // 这里只做落地。模型档位走 applyImportedSettings 而不是 setModel ——
    // 后者会连带套用该档的推荐采样参数,把用户**没勾**的 Steps/CFG 一起改掉。
    if (_inComfy) {
      final applyRes = _useRes && _hasRes;
      notifier.applyImportedSettings(
        model: _useModel ? animaModelFromSource(m.source) : null,
        width: applyRes ? m.width : null,
        height: applyRes ? m.height : null,
        animaSteps: _useSteps ? int.tryParse(m.steps ?? '') : null,
        animaCfg: _useCfg ? double.tryParse(m.scale ?? '') : null,
        animaSampler: _useSampler ? m.sampler : null,
        animaScheduler: _useScheduler ? m.noiseSchedule : null,
        seed: _useSeed && m.seed.isNotEmpty ? m.seed : null,
      );

      // LoRA:勾中的都挂上(权重/CLIP 权重按元数据带回)。库里没有的走占位 +
      // 后台下载,装好就地转正。触发词已经在导入的提示词里了,不再重复拼。
      final picked = <ActiveLora>[];
      for (var i = 0; i < _loraHits.length; i++) {
        final h = _loraHits[i];
        if (h == null || !_loraChecked.contains(i)) continue;
        if (h.isLocal && h.item != null) {
          picked.add(_activeLoraOf(h));
        } else if (h.isCivitai) {
          final p = _pendingLoraOf(h);
          if (p != null) picked.add(p);
        }
      }
      if (picked.isNotEmpty) {
        // applyLoraSelection 语义是「按这份整体替换」,追加时先并上已挂的
        // (同名以导入的为准 —— 用户要的是图里那个权重)。
        final toApply = _loraAppend
            ? <ActiveLora>[
                for (final old in ref.read(generateProvider).loras)
                  if (!picked.any((p) => p.name == old.name)) old,
                ...picked,
              ]
            : picked;
        final n = notifier.applyLoraSelection(toApply);
        msgs.add('$n 个 LoRA');
      }
    }

    // Vibe:有原图的带图导入(生成时按当前模型现场编码);仅编码的挂到
    // 来源模型的编码键下(换模型生成时无原图可重编码,会被停用提示)。
    if (_inNai && _vibeChecked.isNotEmpty) {
      if (!_vibeAppend) notifier.restoreVibes(const []);
      final idx = _vibeChecked.toList()..sort();
      final encKey = _vibeEncKey;
      var added = 0, encOnly = 0;
      for (final i in idx) {
        final b = _vibeBytes[i];
        final enc = m.vibes[i].encoding;
        if (b == null && (enc == null || encKey == null)) continue;
        notifier.addVibe(
          image: b,
          name: '导入的 Vibe ${added + 1}',
          strength: m.vibes[i].strength,
          infoExtracted: m.vibes[i].informationExtracted ?? 1.0,
          encodedByModel: b == null ? {encKey!: enc!} : null,
        );
        added++;
        if (b == null) encOnly++;
      }
      if (encOnly > 0) msgs.add('$encOnly 个 Vibe 仅编码,只在 $_importModel 下可用');
    }

    _finish(
      msgs.isEmpty ? '已导入到创作页' : '已导入 · ${msgs.join(' · ')}',
      Icons.download_done,
    );
  }

  /// 顶部 toast 提示并关闭面板(toast 挂 root overlay,pop 后仍然在)。
  /// 导入/用作都是写创作页,按硬约束自动切回创作 tab(从图库进来时生效)。
  void _finish(String text, IconData icon) {
    hintSnack(context, text, icon: icon);
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
    Navigator.of(context).pop();
  }

  // ---- 用作 ----
  Future<void> _useAsImg2img() async {
    final bytes = widget.bytes;
    final (rw, rh) = await decodeImageSize(bytes);
    if (!mounted) return;
    final res = img2imgResolution(rw, rh);
    final before = ref.read(generateProvider).params;
    ref
        .read(generateProvider.notifier)
        .setImg2ImgImage(image: bytes, width: res.w, height: res.h);
    final changed = before.width != res.w || before.height != res.h;
    _finish(
      changed ? '已设为图生图底图 · 分辨率 ${res.w}×${res.h}' : '已设为图生图底图',
      Icons.image_outlined,
    );
  }

  Future<void> _useAsVibe() async {
    final bytes = widget.bytes;
    final hash = await compute(_sha256Hex, bytes);
    if (!mounted) return;
    try {
      await ref
          .read(vibeLibraryProvider.notifier)
          .importImageBytes(bytes, widget.displayName, knownHash: hash);
    } catch (_) {}
    if (!mounted) return;
    final hadCharRefs = ref.read(generateProvider).enabledCharRefs > 0;
    ref
        .read(generateProvider.notifier)
        .addVibe(image: bytes, name: widget.displayName, imageHash: hash);
    _finish(
      hadCharRefs ? '已加入 Vibe · 与角色参考互斥,已暂停角色参考' : '已加入 Vibe 参考',
      hadCharRefs ? Icons.swap_horiz : Icons.palette_outlined,
    );
  }

  Future<void> _useAsCharRef() async {
    final bytes = widget.bytes;
    final hash = await compute(_sha256Hex, bytes);
    if (!mounted) return;
    try {
      await ref
          .read(charLibraryProvider.notifier)
          .importImageBytes(bytes, widget.displayName, knownHash: hash);
    } catch (_) {}
    if (!mounted) return;
    final hadVibes = ref.read(generateProvider).enabledVibes > 0;
    ref
        .read(generateProvider.notifier)
        .addCharRef(image: bytes, name: widget.displayName, imageHash: hash);
    _finish(
      hadVibes ? '已加入角色参考 · 与 Vibe 互斥,已暂停 Vibe' : '已加入角色参考',
      hadVibes ? Icons.swap_horiz : Icons.face_retouching_natural,
    );
  }

  /// AI 反推:弹窗选模型 → 反推 → 成功后关弹窗,面板切到「反推结果」单条正向页。
  Future<void> _reverse() async {
    final tags = await showDialog<String>(
      context: context,
      builder: (_) => _ReverseDialog(bytes: widget.bytes),
    );
    if (tags == null || tags.isEmpty || !mounted) return;
    setState(() {
      _reverseTags = tags;
      _useReverse = true;
    });
  }

  /// 导入反推结果:把标签串写为正向提示词(替换)。
  void _importReverse() {
    final tags = _reverseTags;
    if (tags == null || !_useReverse) return;
    ref.read(generateProvider.notifier).setPrompts(positive: tags);
    _finish('已导入反推结果到正向提示词', Icons.download_done);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_reverseTags != null) {
      body = SafeArea(top: false, child: _reverseBody(scheme));
    } else {
      body = SafeArea(
        top: false,
        child: _meta == null ? _noMetaBody(scheme) : _mainBody(scheme),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_reverseTags != null ? 'AI 反推结果' : '导入图片'),
        centerTitle: true,
      ),
      body: body,
      // 无元数据时四个「用作」按钮已移到正文居中,底栏留空,避免大片空档 + 吊底。
      bottomNavigationBar: _loading || (_meta == null && _reverseTags == null)
          ? null
          : _bottomBar(scheme),
    );
  }

  // ---- 反推结果:只有一条正向提示词 ----
  Widget _reverseBody(ColorScheme scheme) {
    final tags = _reverseTags!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      children: [
        _infoCard(scheme, reverse: true),
        const SizedBox(height: 16),
        Text(
          '反推结果',
          style: context.texts.titleMedium!.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 11),
        _fixedRow(
          scheme,
          icon: Icons.notes,
          title: '正向提示词',
          preview: tags,
          checked: _useReverse,
          onTap: () => setState(() => _useReverse = !_useReverse),
        ),
      ],
    );
  }

  // ---- 无元数据:顶部信息 + 提示,四个「用作」按钮居中(不再吊在底部留大空档) ----
  Widget _noMetaBody(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _infoCard(scheme, noMeta: true),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: scheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '未在这张图里找到生成参数,仍可把它用作参考。',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '把这张图用作',
                    textAlign: TextAlign.center,
                    style: context.texts.bodyMedium!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _useAsRow(scheme, reverse: false),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 主体 ----
  Widget _mainBody(ColorScheme scheme) {
    final m = _meta!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      children: [
        _infoCard(scheme),
        const SizedBox(height: 16),
        // 跨类别:说清这是哪个模型的图,给一键切过去;不切就只导提示词
        if (_crossCategory) ...[
          _crossCategoryBanner(scheme, m),
          const SizedBox(height: 14),
        ],
        Text(
          '导入到生成页',
          style: context.texts.titleMedium!.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 11),
        // 正向
        if (m.prompt.isNotEmpty) ...[
          _fixedRow(
            scheme,
            icon: Icons.notes,
            title: '正向提示词',
            preview: m.prompt,
            checked: _usePrompt,
            onTap: () => setState(() => _usePrompt = !_usePrompt),
          ),
          const SizedBox(height: 9),
        ],
        // 负向
        if (m.negativePrompt.isNotEmpty) ...[
          _fixedRow(
            scheme,
            icon: Icons.block,
            title: '负向提示词',
            preview: m.negativePrompt,
            checked: _useNegative,
            onTap: () => setState(() => _useNegative = !_useNegative),
            danger: true,
          ),
          const SizedBox(height: 9),
        ],
        // 权重语法转换:只在「源是 a1111、目标是 NovelAI」时出现
        if (_showConvert) ...[_convertRow(scheme), const SizedBox(height: 9)],
        // 角色
        if (_inNai && m.characters.isNotEmpty) ...[
          _charSection(scheme, m),
          const SizedBox(height: 9),
        ],
        // Vibe
        if (_inNai && m.vibes.isNotEmpty) ...[
          _vibeSection(scheme, m),
          const SizedBox(height: 9),
        ],
        // LoRA:哈希→名称→Civitai 三级认领,库里没有的随导入后台下载。
        // 排在生成设置之前 —— 缺 LoRA 往往要先下载(有等待),让人先看见先动手。
        // 仅 anima → anima 出现:NAI 出图链路没有 LoraLoader,摆出来点了也不会生效。
        if (_inComfy && m.loras.isNotEmpty) ...[
          _loraSection(scheme, m),
          const SizedBox(height: 9),
        ],
        // 生成设置
        if (_settingItems.isNotEmpty) ...[
          _settingsSection(scheme, m),
          const SizedBox(height: 9),
        ],
      ],
    );
  }

  /// 跨类别横幅:哪个模型的图 + 当前是什么 + 一键切过去。
  Widget _crossCategoryBanner(ColorScheme scheme, ImageMetadata m) {
    final imageCat = _imageCategory;
    final text = imageCat != null
        ? '这是 ${categoryLabel(imageCat)} 模型的图片,当前为 ${categoryLabel(_targetCategory)} 模型,只能导入提示词。'
        : '${_sourceLabel(m.sourceType)} 图片在本机没有对应的模型,只能导入提示词。';
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.tertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: context.texts.bodySmall!.copyWith(height: 1.5),
                ),
                if (imageCat != null) ...[
                  const SizedBox(height: 9),
                  if (_canSwitchCategory)
                    FilledButton.tonalIcon(
                      onPressed: _switchCategory,
                      icon: const Icon(Icons.swap_horiz, size: 17),
                      label: Text('切换到 ${categoryLabel(imageCat)} 模型'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                  else
                    Text(
                      'Anima 需要 Bot 授权登录后可用,无法切换',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 自动转换提示词格式开关。
  Widget _convertRow(ColorScheme scheme) {
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _convertPrompt = !_convertPrompt),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 13, 12),
          child: Row(
            children: [
              Icon(Icons.translate, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '自动转换提示词格式',
                      style: context.texts.bodyLarge!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '把 (tag:1.2) 转成 NovelAI 的 1.2::tag::',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _checkBox(scheme, _convertPrompt),
            ],
          ),
        ),
      ),
    );
  }

  /// LoRA 区:与 Vibe 同一副骨架(_section 外壳 + 42px 缩略图行 + 同款勾选框),
  /// 不再是之前那种细行小字的自制样式。
  Widget _loraSection(ColorScheme scheme, ImageMetadata m) {
    // 能挂的 = 库里有的 + Civitai 上有的(后者导入后自动下载)
    final mountable = [
      for (var i = 0; i < _loraHits.length; i++)
        if (_loraHits[i]?.isLocal == true || _loraHits[i]?.isCivitai == true) i,
    ];
    final allOn =
        mountable.isNotEmpty && _loraChecked.length == mountable.length;
    return _section(
      scheme,
      icon: Icons.layers_outlined,
      iconColor: scheme.primary,
      title: 'LoRA',
      count: '${_loraChecked.length}/${mountable.length}',
      allOn: allOn,
      onToggleAll: mountable.isEmpty
          ? null
          : () => setState(() {
              if (allOn) {
                _loraChecked.clear();
              } else {
                _loraChecked
                  ..clear()
                  ..addAll(mountable);
              }
            }),
      expanded: _loraExpanded,
      onToggleExpand: () => setState(() => _loraExpanded = !_loraExpanded),
      child: Column(
        children: [
          _overrideSeg(
            scheme,
            _loraAppend,
            (v) => setState(() => _loraAppend = v),
          ),
          const SizedBox(height: 9),
          if (_resolvingLoras)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(
                children: [
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    '正在认领…',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          for (var i = 0; i < m.loras.length; i++) ...[
            _loraRow(scheme, m.loras[i], _loraHits.elementAtOrNull(i), i),
            if (i != m.loras.length - 1) const SizedBox(height: 9),
          ],
        ],
      ),
    );
  }

  /// 一条 LoRA:缩略图 + 名字 + 状态副行 + 右侧动作(勾选 / 不可用)。
  Widget _loraRow(
    ColorScheme scheme,
    LoraInfo lora,
    LoraResolveResult? hit,
    int index,
  ) {
    final selectable = hit?.isLocal == true || hit?.isCivitai == true;
    final picked = selectable && _loraChecked.contains(index);
    // 非 Anima 底模装了也用不上(不生效或画崩),必须显眼
    final wrongBase =
        hit != null &&
        hit.isCivitai &&
        hit.civitaiBaseModel.isNotEmpty &&
        !hit.civitaiBaseModel.toLowerCase().contains('anima');

    // 副行:状态 + 权重,和 Vibe 行的参数副行同一套排版
    final weightText = lora.clipWeight == null
        ? '权重 ${lora.weight}'
        : '权重 ${lora.weight} · CLIP ${lora.clipWeight}';
    final String status;
    Color statusColor = scheme.onSurfaceVariant;
    if (hit == null) {
      status = _resolvingLoras ? '认领中' : '未认领';
    } else if (hit.isLocal) {
      status = hit.matchedBy == 'name' ? '名称匹配·版本可能不同' : '库中已有';
      if (hit.matchedBy == 'name') statusColor = scheme.tertiary;
    } else if (hit.isCivitai) {
      status = wrongBase
          ? 'Civitai · 底模 ${hit.civitaiBaseModel}'
          : 'Civitai · 导入后自动下载';
      if (wrongBase) statusColor = scheme.error;
    } else {
      status = (lora.hash?.isNotEmpty ?? false)
          ? '库中与 Civitai 都没有'
          : '无哈希,只能靠名字找';
    }

    final preview = hit?.item?.previewUrl.isNotEmpty == true
        ? hit!.item!.previewUrl
        : (hit?.civitaiPreviewUrl ?? '');

    return Opacity(
      opacity: hit == null || hit.isLocal || hit.isCivitai ? 1 : .5,
      child: InkWell(
        onTap: selectable
            ? () => setState(() {
                if (!_loraChecked.remove(index)) _loraChecked.add(index);
              })
            : null,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: preview.isEmpty
                      ? Container(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.auto_awesome_outlined,
                            size: 20,
                            color: scheme.outline,
                          ),
                        )
                      : RemoteImage(
                          preview,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: scheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.auto_awesome_outlined,
                              size: 20,
                              color: scheme.outline,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hit?.label ?? lora.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodyMedium!.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$status · $weightText',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, size: 10.5, color: statusColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (selectable)
                _checkBox(scheme, picked, size: 20)
              else if (hit != null && !_resolvingLoras)
                Icon(Icons.block, size: 18, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 顶部信息卡 ----
  Widget _infoCard(
    ColorScheme scheme, {
    bool noMeta = false,
    bool reverse = false,
  }) {
    final m = _meta;
    final simple = noMeta || reverse; // 无徽标 / 无原始元数据入口
    final hasDims = m != null && (m.width > 0 || m.height > 0);
    final String subtitle;
    if (hasDims) {
      subtitle = '${m.width}×${m.height} · $_sizeText';
    } else if (noMeta && !reverse) {
      subtitle = '未找到生成参数 · $_sizeText';
    } else {
      subtitle = _sizeText;
    }
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Image.memory(
              widget.bytes,
              width: 56,
              height: 70,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  simple || m == null ? widget.fileName : m.source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: mono(
                    context,
                    size: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (m != null && !simple) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 5,
                    children: [
                      if (m.characters.isNotEmpty)
                        _badge(
                          scheme,
                          '${m.characters.length} 角色',
                          scheme.tertiary,
                        ),
                      if (m.vibes.isNotEmpty)
                        _badge(
                          scheme,
                          '${m.vibes.length} Vibe',
                          scheme.primary,
                        ),
                      if (m.loras.isNotEmpty)
                        _badge(
                          scheme,
                          '${m.loras.length} Lora',
                          scheme.secondary,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // 原始元数据入口
          if (m != null && !simple)
            _RawEntry(
              onTap: () {
                Navigator.of(context).push(
                  sharedAxisRoute(
                    MetadataDetailPage(
                      meta: m,
                      bytes: widget.bytes,
                      fileName: widget.fileName,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _badge(ColorScheme scheme, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // ---- 固定预览行(正/负) ----
  Widget _fixedRow(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String preview,
    required bool checked,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final expanded = _expandedRows.contains(title);
    final textColor = danger ? scheme.error : scheme.onSurfaceVariant;
    // 与创作页 SectionCard 同一套手势分工:**整行点 = 展开/收起**,尾部
    // chevron 只是指示器(不接手势),勾选交给独立点击域的勾选框。
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(
              () => expanded
                  ? _expandedRows.remove(title)
                  : _expandedRows.add(title),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 13, 12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: danger ? scheme.error : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: context.texts.bodyLarge!.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        // 展开后全文就在下面,单行预览留着只是重复
                        if (!expanded) ...[
                          const SizedBox(height: 2),
                          Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: textColor),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 勾选:自带点击域,不连带展开
                  InkResponse(
                    onTap: onTap,
                    radius: 22,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _checkBox(scheme, checked),
                    ),
                  ),
                  const SizedBox(width: 5),
                  AnimatedRotation(
                    turns: expanded ? .5 : 0,
                    duration: Motion.medium,
                    curve: Motion.emphasized,
                    child: Icon(
                      Icons.expand_more,
                      size: 22,
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 全文:可选中,给"只想抄其中几个 tag"的场景。放在可点击行之外 ——
          // SelectableText 要吃住长按/拖拽手势,套进 InkWell 会跟点击打架。
          ExpandBody(
            expanded: expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 13),
              child: SelectableText(
                preview,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.55,
                  color: textColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 角色 section ----
  Widget _charSection(ColorScheme scheme, ImageMetadata m) {
    final total = m.characters.length;
    final allOn = _charChecked.length == total;
    return _section(
      scheme,
      icon: Icons.group,
      iconColor: scheme.tertiary,
      title: '角色提示词',
      count: '${_charChecked.length}/$total',
      allOn: allOn,
      onToggleAll: () => setState(() {
        if (allOn) {
          _charChecked.clear();
        } else {
          _charChecked
            ..clear()
            ..addAll([for (var i = 0; i < total; i++) i]);
        }
      }),
      expanded: _charExpanded,
      onToggleExpand: () => setState(() => _charExpanded = !_charExpanded),
      child: Column(
        children: [
          _overrideSeg(
            scheme,
            _charAppend,
            (v) => setState(() => _charAppend = v),
          ),
          const SizedBox(height: 9),
          for (var i = 0; i < total; i++) ...[
            // 站位跟着角色勾选一起导入,tag 只标站位 —— 「角色 N」是行序
            // 本身就看得出来的信息,占着位置反而把真正有用的格号挤窄。
            _itemRow(
              scheme,
              tag:
                  gridPosOfCenter(
                    m.characters[i].centerX,
                    m.characters[i].centerY,
                  ) ??
                  'AUTO',
              tagColor: scheme.tertiary,
              text: m.characters[i].prompt,
              checked: _charChecked.contains(i),
              onTap: () => setState(() {
                _charChecked.contains(i)
                    ? _charChecked.remove(i)
                    : _charChecked.add(i);
              }),
            ),
            if (i != total - 1) const SizedBox(height: 9),
          ],
        ],
      ),
    );
  }

  // ---- Vibe section ----
  Widget _vibeSection(ColorScheme scheme, ImageMetadata m) {
    final total = m.vibes.length;
    final importable = [
      for (var i = 0; i < total; i++)
        if (_vibeImportable(m, i)) i,
    ];
    final allOn =
        importable.isNotEmpty && _vibeChecked.length == importable.length;
    return _section(
      scheme,
      icon: Icons.palette_outlined,
      iconColor: scheme.primary,
      title: 'Vibe',
      count: '${_vibeChecked.length}/${importable.length}',
      allOn: allOn,
      onToggleAll: () => setState(() {
        if (allOn) {
          _vibeChecked.clear();
        } else {
          _vibeChecked
            ..clear()
            ..addAll(importable);
        }
      }),
      expanded: _vibeExpanded,
      onToggleExpand: () => setState(() => _vibeExpanded = !_vibeExpanded),
      child: Column(
        children: [
          _overrideSeg(
            scheme,
            _vibeAppend,
            (v) => setState(() => _vibeAppend = v),
          ),
          const SizedBox(height: 9),
          for (var i = 0; i < total; i++) ...[
            _vibeRow(scheme, m, i),
            if (i != total - 1) const SizedBox(height: 9),
          ],
        ],
      ),
    );
  }

  Widget _vibeRow(ColorScheme scheme, ImageMetadata m, int i) {
    final v = m.vibes[i];
    final thumb = _vibeBytes[i];
    final importable = _vibeImportable(m, i);
    final checked = _vibeChecked.contains(i);
    final params =
        '强度 ${v.strength.toStringAsFixed(2)} · IE ${(v.informationExtracted ?? 1.0).toStringAsFixed(1)}';
    final String sub;
    if (thumb != null) {
      sub = params;
    } else if (importable) {
      sub = '仅编码 · $params';
    } else if (v.encoding != null) {
      sub = '仅编码 · 来源模型未知,无法导入';
    } else {
      // needsLocalMatch:元数据里只有强度参数,既无原图也无编码
      sub = '仅有参数,无法导入';
    }
    return Opacity(
      opacity: importable ? 1 : .5,
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          children: [
            StripeThumb(width: 42, height: 42, radius: 9, image: thumb),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Vibe ${i + 1}',
                    style: context.texts.bodyMedium!.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: mono(
                      context,
                      size: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (importable)
              GestureDetector(
                onTap: () => setState(() {
                  checked ? _vibeChecked.remove(i) : _vibeChecked.add(i);
                }),
                child: _checkBox(scheme, checked, size: 20),
              )
            else
              Icon(Icons.block, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  // ---- 生成设置 section ----
  Widget _settingsSection(ColorScheme scheme, ImageMetadata m) {
    final unsupported = _settingsUnsupportedReason;
    final items = _settingItems;
    // 计数只算真能导的项:超出支持面的格子勾不上,算进分母会让「3/8」看着像漏勾了
    final selectable = items.where((e) => e.unsupportedReason == null).toList();
    final checkedCount = unsupported != null
        ? 0
        : selectable.where((e) => e.on).length;
    final allOn =
        unsupported == null &&
        selectable.isNotEmpty &&
        selectable.every((e) => e.on);
    return _section(
      scheme,
      icon: Icons.tune,
      iconColor: scheme.primary,
      title: '生成设置',
      count: '$checkedCount/${selectable.length}',
      allOn: allOn,
      onToggleAll: unsupported != null || selectable.isEmpty
          ? null
          : () => setState(() {
              final target = !allOn;
              for (final e in selectable) {
                e.set(target);
              }
            }),
      expanded: _settingsExpanded,
      onToggleExpand: () =>
          setState(() => _settingsExpanded = !_settingsExpanded),
      child: unsupported != null
          ? InfoNote(
              '含当前版本不支持的参数($unsupported),无法导入生成设置。',
              icon: Icons.warning_amber_rounded,
            )
          : LayoutBuilder(
              builder: (context, c) {
                const gap = 8.0;
                final w = (c.maxWidth - gap) / 2;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    // 模型/Seed 值长,分辨率凑数也整行 —— 这样满字段时正好
                    // Steps+CFG / Rescale+Variety+ / Sampler+Scheduler 三对。
                    for (final e in items)
                      SizedBox(
                        width:
                            (e.label == 'Seed' ||
                                e.label == '模型' ||
                                e.label == '分辨率')
                            ? c.maxWidth
                            : w,
                        child: _settingTile(scheme, e),
                      ),
                  ],
                );
              },
            ),
    );
  }

  Widget _settingTile(ColorScheme scheme, _SettingSpec e) {
    final blocked = e.unsupportedReason != null;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: blocked ? null : () => setState(() => e.set(!e.on)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.label,
                      style: TextStyle(fontSize: 10, color: scheme.outline),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          mono(
                            context,
                            size: 13,
                            color: blocked ? scheme.outline : null,
                          ).copyWith(
                            decoration: blocked
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                    ),
                    // 只废掉这一格并说明原因,不牵连整组其它字段
                    if (blocked)
                      Text(
                        e.unsupportedReason!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: scheme.error),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (blocked)
                Icon(Icons.block, size: 18, color: scheme.outline)
              else
                _checkBox(scheme, e.on, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 通用小部件 ----
  Widget _checkBox(ColorScheme scheme, bool on, {double size = 22}) {
    return AnimatedContainer(
      duration: Motion.fast,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: on ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: on ? null : Border.all(color: scheme.outline, width: 1.6),
      ),
      child: on
          ? Icon(Icons.check, size: size * 0.7, color: scheme.onPrimary)
          : null,
    );
  }

  /// 完全覆盖 / 额外添加 分段(滑块式,带切换动画)
  Widget _overrideSeg(
    ColorScheme scheme,
    bool append,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      children: [
        Text(
          '导入方式',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        const Spacer(),
        _SlideSeg(
          options: const ['完全覆盖', '额外添加'],
          index: append ? 1 : 0,
          onChanged: (i) => onChanged(i == 1),
        ),
      ],
    );
  }

  /// 可展开分组容器(头部:图标 + 标题 + 计数 + 全选 + 展开箭头)。
  Widget _section(
    ColorScheme scheme, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String count,
    required bool allOn,
    required VoidCallback? onToggleAll,
    required bool expanded,
    required VoidCallback onToggleExpand,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: onToggleExpand,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 13, 13),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: iconColor),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: context.texts.bodyLarge!.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    count,
                    style: mono(context, size: 12.5, color: iconColor),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: onToggleAll,
                    child: _checkBox(scheme, allOn),
                  ),
                  const SizedBox(width: 10),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: Motion.fast,
                    child: Icon(
                      Icons.expand_more,
                      size: 22,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 13),
              child: child,
            ),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: Motion.fast,
          ),
        ],
      ),
    );
  }

  /// 角色行:标签 chip + 文本 + 勾选。
  Widget _itemRow(
    ColorScheme scheme, {
    required String tag,
    required Color tagColor,
    required String text,
    required bool checked,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: tagColor.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  fontSize: 10.5,
                  color: tagColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text.isEmpty ? '(空)' : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            _checkBox(scheme, checked, size: 20),
          ],
        ),
      ),
    );
  }

  // ---- 底部栏 ----
  Widget _bottomBar(ColorScheme scheme) {
    final reverse = _reverseTags != null;
    final showCta = reverse || _meta != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _useAsRow(scheme, reverse: reverse),
            if (showCta) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 54,
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: reverse
                      ? (_useReverse ? _importReverse : null)
                      : (_hasAnySelection ? _import : null),
                  icon: const Icon(Icons.download, size: 22),
                  label: const Text(
                    '导入所选内容',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 四个「用作」按钮一行(反推结果页不重复提供「反推」)。
  Widget _useAsRow(ColorScheme scheme, {required bool reverse}) {
    return Row(
      children: [
        _useAsBtn(scheme, Icons.image_outlined, '图生图', _useAsImg2img),
        const SizedBox(width: 8),
        _useAsBtn(scheme, Icons.palette_outlined, '风格', _useAsVibe),
        const SizedBox(width: 8),
        _useAsBtn(scheme, Icons.face_retouching_natural, '角色', _useAsCharRef),
        if (!reverse) ...[
          const SizedBox(width: 8),
          _useAsBtn(scheme, Icons.auto_awesome, '反推', _reverse),
        ],
      ],
    );
  }

  Widget _useAsBtn(
    ColorScheme scheme,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(13),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 58,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: scheme.primary),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _sourceLabel(ImageSourceType t) => switch (t) {
    ImageSourceType.novelai => 'NovelAI',
    ImageSourceType.stableDiffusion => 'Stable Diffusion',
    ImageSourceType.comfyui => 'ComfyUI',
    ImageSourceType.unknown => '未知来源',
  };
}

/// 顶卡右侧「原始元数据」竖分栏入口。
class _RawEntry extends StatelessWidget {
  const _RawEntry({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 52,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.data_object, size: 20, color: scheme.primary),
            const SizedBox(height: 3),
            Text(
              '原始\n元数据',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 8.5,
                height: 1.2,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingSpec {
  _SettingSpec(
    this.label,
    this.value,
    this.on,
    this._setter, {
    this.unsupportedReason,
  });
  final String label;
  final String value;

  /// 该项超出本机支持面时的原因(采样器不在白名单、步数超范围…)。
  /// 有值 = 这一格禁选并显示原因,只废掉这一项,不牵连整组其它字段。
  final String? unsupportedReason;
  bool on;
  final void Function(bool) _setter;
  void set(bool v) {
    on = v;
    _setter(v);
  }
}

/// 滑块式分段控件:选中态是一块滑动的圆角指示块(AnimatedPositioned),
/// 文字颜色随之渐变,切换带触感。
class _SlideSeg extends StatelessWidget {
  const _SlideSeg({
    required this.options,
    required this.index,
    required this.onChanged,
  });

  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;

  static const double _optWidth = 76;
  static const double _height = 30;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
      ),
      child: SizedBox(
        width: _optWidth * options.length,
        height: _height,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: Motion.medium,
              curve: Motion.emphasized,
              left: index * _optWidth,
              top: 0,
              bottom: 0,
              width: _optWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < options.length; i++)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (i == index) return;
                      Haptics.selection();
                      onChanged(i);
                    },
                    child: SizedBox(
                      width: _optWidth,
                      height: _height,
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: Motion.medium,
                          curve: Motion.standard,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: i == index
                                ? scheme.onPrimary
                                : scheme.onSurfaceVariant,
                          ),
                          child: Text(options[i]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 反推弹窗:选反推模型(当前仅一个)→ 开始反推 → 成功后 pop 返回标签串。
/// 走 Bot 后端 `/api/wd-tagger`(转发 HuggingFace tagger Space)。
class _ReverseDialog extends ConsumerStatefulWidget {
  const _ReverseDialog({required this.bytes});
  final Uint8List bytes;

  @override
  ConsumerState<_ReverseDialog> createState() => _ReverseDialogState();
}

class _ReverseDialogState extends ConsumerState<_ReverseDialog> {
  bool _running = false;
  String? _error;
  int _model = 0; // 预留多模型;当前仅一个

  Future<void> _start() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final session = await ref.read(botSessionProvider.future);
      if (session == null) {
        throw Exception('AI 反推需 Bot 后端会话,请先在「我的」里登录 Bot');
      }
      final b64 = base64Encode(widget.bytes);
      final r = await ref
          .read(backendClientProvider)
          .wdTagger(sessionId: session.sessionId, imageBase64: b64);
      if (!r.success || r.tags.isEmpty) {
        throw Exception(r.message.isNotEmpty ? r.message : '反推失败,请稍后重试');
      }
      if (!mounted) return;
      Navigator.of(context).pop(r.tags);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return AlertDialog(
      title: const Text('AI 反推'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选择反推模型',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            _modelOption(
              scheme,
              0,
              'pixai-tagger',
              'Danbooru 标签体系 · 识别角色 / 画风 / 通用标签',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 16, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ],
            if (_running) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '反推中,请稍候…',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _running ? null : _start,
          child: const Text('开始反推'),
        ),
      ],
    );
  }

  Widget _modelOption(ColorScheme scheme, int index, String name, String desc) {
    final selected = _model == index;
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: .35)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _running ? null : () => setState(() => _model = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: context.texts.bodyMedium!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
