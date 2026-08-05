/// 创作页 UI 状态模型。当前里程碑仅承载界面,后续接 NAI API 时补充序列化。
library;

import 'dart:typed_data';

import 'res_rules.dart' show kFreePixelThreshold;

const Object _unset = Object();

/// 角色提示词当前编辑面
enum CharTab { positive, negative }

class CharacterPrompt {
  const CharacterPrompt({
    required this.id,
    required this.name,
    this.positive = '',
    this.negative = '',
    this.positiveRaw = '',
    this.negativeRaw = '',
    this.enabled = true,
    this.position, // 'A1'..'E5';null = AUTO
    this.activeTab = CharTab.positive,
  });

  final String id;
  final String name;
  final String positive;
  final String negative;

  /// 编辑器原文草稿(含禁用 `~tag~` / 折叠 `<#名字: …>` 等仅编辑期语法),
  /// 空 = 与定稿无差别,不必单独存。有效性由读取侧判定,见 [pickEditorText]。
  final String positiveRaw;
  final String negativeRaw;

  final bool enabled;
  final String? position;
  final CharTab activeTab;

  CharacterPrompt copyWith({
    String? name,
    String? positive,
    String? negative,
    String? positiveRaw,
    String? negativeRaw,
    bool? enabled,
    Object? position = _unset,
    CharTab? activeTab,
  }) {
    return CharacterPrompt(
      id: id,
      name: name ?? this.name,
      positive: positive ?? this.positive,
      negative: negative ?? this.negative,
      positiveRaw: positiveRaw ?? this.positiveRaw,
      negativeRaw: negativeRaw ?? this.negativeRaw,
      enabled: enabled ?? this.enabled,
      position: position == _unset ? this.position : position as String?,
      activeTab: activeTab ?? this.activeTab,
    );
  }
}

class VibeItem {
  const VibeItem({
    required this.id,
    this.name = '',
    this.enabled = true,
    this.strength = 0.6,
    this.infoExtracted = 1.0,
    this.image,
    this.imageHash,
    this.encodedByModel,
    this.sourceId,
  });

  final String id;
  final String name; // 来源文件名/展示名
  final bool enabled;
  final double strength;
  final double infoExtracted;

  /// 原始图片字节(用户选的图);编码时用,缩略图也用它显示。
  final Uint8List? image;

  /// 图片内容哈希(sha256 hex),编码缓存键用——内容寻址,重选同图/重启后仍可命中。
  final String? imageHash;

  /// 纯编码 vibe(库导入的 type:'encoding' 文件,无原图):
  /// encodings 键(v4-5full 等)→ 编码串;生成时按当前模型取,取不到跳过。
  /// IE 随文件固定,不可调。
  final Map<String, String>? encodedByModel;

  /// 来源库条目 id(从 Vibe 库添加/自动入库时有),生成成功后回写「最近使用」。
  final String? sourceId;

  /// 只有编码没有原图(IE 滑条锁定,无法重编码)。
  bool get isEncodingOnly => image == null;

  VibeItem copyWith({bool? enabled, double? strength, double? infoExtracted}) =>
      VibeItem(
        id: id,
        name: name,
        enabled: enabled ?? this.enabled,
        strength: strength ?? this.strength,
        infoExtracted: infoExtracted ?? this.infoExtracted,
        image: image,
        imageHash: imageHash,
        encodedByModel: encodedByModel,
        sourceId: sourceId,
      );
}

/// 角色参考迁移模式。label 显示用;api 直接进载荷 base_caption(对齐 web)。
enum CharRefMode {
  character('角色', 'character'),
  style('风格', 'style'),
  both('角色&风格', 'character&style');

  const CharRefMode(this.label, this.api);
  final String label;
  final String api;
}

class CharRefItem {
  const CharRefItem({
    required this.id,
    this.name = '',
    this.enabled = true,
    this.mode = CharRefMode.both,
    this.strength = 1.0,
    this.infoExtracted = 1.0,
    this.image,
    this.imageHash,
  });

  final String id;
  final String name;
  final bool enabled;
  final CharRefMode mode;
  final double strength;

  /// UI 上的「保真度 Fidelity」;载荷 secondary_strength = 1 - infoExtracted。
  /// (director_reference_information_extracted 本身恒为 1,故此字段其实是 Fidelity。)
  final double infoExtracted;
  final Uint8List? image;
  final String? imageHash;

  CharRefItem copyWith({
    bool? enabled,
    CharRefMode? mode,
    double? strength,
    double? infoExtracted,
  }) => CharRefItem(
    id: id,
    name: name,
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    strength: strength ?? this.strength,
    infoExtracted: infoExtracted ?? this.infoExtracted,
    image: image,
    imageHash: imageHash,
  );
}

/// 一次重绘任务的完整载荷(由重绘编辑器构造,只存在于生成快照中,
/// 不进创作页 UI)。image/mask 已按发送尺寸备好(整图或 64 对齐的局部框)。
class InpaintJob {
  const InpaintJob({
    required this.image,
    required this.mask,
    required this.strength,
    this.paste,
  });

  /// 发送底图 PNG(整图重绘=原图;局部=裁切子图)。
  final Uint8List image;

  /// 与 image 同尺寸的黑白 mask PNG(白=重绘区,已 8×8 对齐)。
  final Uint8List mask;

  final double strength;

  /// 局部重绘的贴回信息;null = 整图(结果直接入库)。
  final InpaintPaste? paste;
}

/// 局部重绘贴回:结果(发送框尺寸)中 tight 区域贴回原图对应位置。
class InpaintPaste {
  const InpaintPaste({
    required this.original,
    required this.sendX,
    required this.sendY,
    required this.tightX,
    required this.tightY,
    required this.tightW,
    required this.tightH,
    required this.outW,
    required this.outH,
  });

  /// 原完整图 PNG(贴回底)。
  final Uint8List original;

  /// 发送框原点(相对原图;发送框尺寸即快照 params.width/height)。
  final int sendX, sendY;

  /// 贴回的紧凑区域(相对原图)。
  final int tightX, tightY, tightW, tightH;

  /// 入库尺寸(=原图尺寸)。
  final int outW, outH;
}

class Img2ImgConfig {
  const Img2ImgConfig({this.strength = 0.7, this.noise = 0.0, this.image});

  final double strength;
  final double noise;

  /// 原始底图字节;生成时 cover 到目标分辨率再编码发送。
  final Uint8List? image;

  Img2ImgConfig copyWith({double? strength, double? noise, Uint8List? image}) =>
      Img2ImgConfig(
        strength: strength ?? this.strength,
        noise: noise ?? this.noise,
        image: image ?? this.image,
      );
}

enum LoopCount {
  x4('4'),
  x8('8'),
  x16('16'),
  infinite('∞');

  const LoopCount(this.label);
  final String label;

  /// 循环张数;0 表示无限(手动停止或失败为止)。
  int get count => switch (this) {
    LoopCount.x4 => 4,
    LoopCount.x8 => 8,
    LoopCount.x16 => 16,
    LoopCount.infinite => 0,
  };
}

class SizePreset {
  const SizePreset(
    this.name,
    this.ratio,
    this.width,
    this.height, {
    this.free = false,
  });
  final String name;
  final String ratio;
  final int width;
  final int height;
  final bool free;
}

/// 分辨率三档
const sizeTabs = <String, List<SizePreset>>{
  '小图': [
    SizePreset('竖图', '2:3', 832, 1216, free: true),
    SizePreset('横图', '3:2', 1216, 832, free: true),
    SizePreset('方形', '1:1', 1024, 1024, free: true),
  ],
  '大图': [
    SizePreset('竖图', '2:3', 1024, 1536),
    SizePreset('横图', '3:2', 1536, 1024),
    SizePreset('方形', '1:1', 1472, 1472),
  ],
  '壁纸': [
    SizePreset('竖屏', '9:16', 1088, 1920),
    SizePreset('横屏', '16:9', 1920, 1088),
    SizePreset('手机', '15:34', 960, 2176),
  ],
};

// 对齐 web 移动端:只保留 V4/V4.5(V3 用另一套载荷,移动端不提供)。
const models = <String>[
  'NAI 4.5 Full',
  'NAI 4.5 Curated',
  'NAI 4.0 Full',
  'NAI 4.0 Curated',
];

/// 角色参考(Director/Precise Reference)仅 4.5 系模型支持(对齐 web 门槛)。
/// 载荷构造 / 成本预估 / 卡片提示共用此判定,入参为 UI 展示名。
bool crSupportsModel(String displayModel) => displayModel.startsWith('NAI 4.5');

// ============================================================
// 模型父类(provider)与 Anima(Modal ComfyUI 后端,仅 Bot 授权可用)
// 与 NAI 是两套完全独立的采样枚举,不要混用(对齐 web animaOptions.ts)。
// ============================================================

/// 模型父类:决定功能模块可见集与出图后端。
enum GenProvider { nai, anima }

GenProvider providerOfModel(String displayModel) =>
    displayModel.startsWith('Anima') ? GenProvider.anima : GenProvider.nai;

bool isAnimaModel(String displayModel) =>
    providerOfModel(displayModel) == GenProvider.anima;

/// Anima 三档模型(展示名后缀即 anima_extra.model 档位)。
const animaModels = <String>['Anima Turbo', 'Anima Aesthetic', 'Anima Base'];

/// 展示名 → 档位串(turbo/aesthetic/base)。
String animaTierOf(String displayModel) => switch (displayModel) {
  'Anima Aesthetic' => 'aesthetic',
  'Anima Base' => 'base',
  _ => 'turbo',
};

/// 模型选择弹层的副标题。**恒为单行**(渲染侧 ellipsis 兜底),内容取
/// web 两版之长:桌面端 `LeftSidebar` 那三句讲**用途**(适合初步生成 /
/// 适合尝试不同风格 / 标准版本),移动端 `MobileGeneratePage` 讲**规格**
/// (蒸馏版、步数)—— 这里合成「规格 · 用途」,一行内给出选型要看的两件事。
///
/// NAI 四档 web 两版一字不差,原样取用。步数与本 app [animaTierDefaults] 的
/// 实际取值对得上(turbo 12 步、aesthetic/base 28 步),不是照抄的死文案。
///
/// 去掉了 Anima Turbo 的「(默认)」:那在 web 指「anima 档位里的默认」,
/// 而本 app 默认模型是 NAI 4.5 Full,七档平铺一张表会被读成"app 的默认"。
/// 分隔符统一用 ` · `(web 的 NAI 用逗号、anima 用点,混着来一页两套版式)。
const modelDescriptions = <String, String>{
  'NAI 4.5 Full': '最新旗舰模型 · NSFW',
  'NAI 4.5 Curated': '最新旗舰精选版 · SFW',
  'NAI 4.0 Full': 'V4 旧模型 · NSFW',
  'NAI 4.0 Curated': 'V4 旧模型精选版 · SFW',
  'Anima Turbo': '蒸馏版 · 12 步 · 快,适合初稿',
  'Anima Aesthetic': '画风美学微调 · 28 步 · 适合试风格',
  'Anima Base': '标准基础模型 · 28 步',
};

/// 采样选项:id 直发服务端,label 供 UI。
class AnimaOption {
  const AnimaOption(this.id, this.label);

  final String id;
  final String label;
}

const animaSamplers = <AnimaOption>[
  AnimaOption('euler', 'Euler'),
  AnimaOption('euler_ancestral', 'Euler Ancestral'),
  AnimaOption('er_sde', 'ER SDE'),
  AnimaOption('dpmpp_2m_sde_gpu', 'DPM++ 2M SDE'),
  AnimaOption('dpmpp_2m', 'DPM++ 2M'),
  AnimaOption('dpmpp_sde_gpu', 'DPM++ SDE'),
];

const animaSchedulers = <AnimaOption>[
  AnimaOption('simple', 'Simple'),
  AnimaOption('karras', 'Karras'),
  AnimaOption('normal', 'Normal'),
  AnimaOption('sgm_uniform', 'SGM Uniform'),
  AnimaOption('beta', 'Beta'),
];

/// UI 推荐范围(对齐 web ANIMA_STEPS_RANGE / ANIMA_CFG_RANGE)。
/// 高级设置的滑块与元数据导入的可用性判断共用这一份,免得两处各自漂。
const animaStepsRange = (min: 6, max: 50);
const animaCfgRange = (min: 1.0, max: 7.0);

/// 各档位推荐采样参数(切档时自动套用;须与服务端 _ANIMA_SLOW_DEFAULTS 一致)。
({int steps, double cfg, String sampler, String scheduler}) animaTierDefaults(
  String tier,
) => switch (tier) {
  'aesthetic' ||
  'base' => (steps: 28, cfg: 4.5, sampler: 'er_sde', scheduler: 'simple'),
  _ => (steps: 12, cfg: 1.0, sampler: 'euler', scheduler: 'simple'),
};

// ── LoRA(anima 专属功能模块) ──────────────────────────────

/// 同时挂载上限(与服务端 lora_resolver.MAX_LORAS_PER_GEN 一致)。
/// 是资源护栏不是画质建议——真正决定画质的是各条权重之和(LoRA 的效果直接相加,
/// 不会因为挂得多就自动摊薄),那个交给用户自己把握。
const kMaxActiveLoras = 20;

/// 权重钳制,与服务端 resolve_ui_loras / web LoraNumberInput 一致。
const kLoraWeightMax = 2.0;

/// 机房还没有这个文件——导入时先占位挂上,后台下载完再就地转正。
class LoraPending {
  const LoraPending({required this.versionId, this.failed});

  /// Civitai 版本号,与安装队列里的任务对齐(实时进度按它去队列取)。
  final int versionId;

  /// 下载失败原因;有值 = 停在失败态,等用户重试或移除。
  final String? failed;
}

/// 占位条目的 name:转正前没有真 LR 编号,用它做去重与选中标识。
String pendingLoraKey(int versionId) => 'pending:$versionId';

/// 类型徽标文案(character/style/concept → 中文;未知原样显示)。
String loraTypeLabel(String type) => switch (type) {
  'character' => '角色',
  'style' => '画风',
  'concept' => '概念',
  _ => type,
};

/// 挂载中的一个 LoRA。[name] 即服务端 LR 编号(LR1…),生成载荷只发它;
/// 其余字段来自注册表卡片,供 UI 展示与触发词交互。
class ActiveLora {
  const ActiveLora({
    required this.name,
    required this.displayName,
    this.weight = 0.8,
    this.enabled = true,
    this.clipWeight,
    this.hasTe,
    this.pending,
    this.triggerWords = const [],
    this.previewUrl = '',
    this.type = 'concept',
  });

  final String name;
  final String displayName;
  final double weight;
  final bool enabled;

  /// LoraLoader 的 strength_clip,与 strength_model 分离;null = 跟随 [weight](默认)。
  /// 叠多个 LoRA 后「prompt 不听话」是文本编码器被一起 patch 推偏导致的,
  /// 单独压低它能保住画面特征同时把语义拉回来。
  final double? clipWeight;

  /// 有没有文本编码器权重(服务端读 safetensors 头探得)。false = 只训了画面侧,
  /// [clipWeight] 调了不会有任何变化 → UI 不给调;null = 未知,按可调处理。
  final bool? hasTe;

  /// 非 null = 机房还没有这个文件(导入时占位挂上,后台下载中)。
  /// 期间 [name] 是 [pendingLoraKey] 生成的占位串,**绝不能进生成载荷**——
  /// 服务端查无此 LoRA 会静默丢弃,等于白跑一次生成。
  final LoraPending? pending;

  /// 全部可选触发词条目(一条可能是逗号分隔的整套 tag)。
  /// 是否写进正向词由用户在卡片上逐条点选(前端所见即所得),
  /// 载荷 triggers 恒传空数组告知服务端不要再拼。
  final List<String> triggerWords;
  final String previewUrl;
  final String type;

  /// [clearClipWeight] = true 时把 CLIP 强度退回「跟随 weight」——
  /// 命名参数传 null 表示「不改」,所以清空需要独立开关。
  ActiveLora copyWith({
    double? weight,
    bool? enabled,
    double? clipWeight,
    bool clearClipWeight = false,
    LoraPending? pending,
  }) => ActiveLora(
    name: name,
    displayName: displayName,
    weight: weight ?? this.weight,
    enabled: enabled ?? this.enabled,
    clipWeight: clearClipWeight ? null : (clipWeight ?? this.clipWeight),
    hasTe: hasTe,
    pending: pending ?? this.pending,
    triggerWords: triggerWords,
    previewUrl: previewUrl,
    type: type,
  );
}

// ── 重绘放大 hires(anima 专属功能模块) ─────────────────────

/// 「先超分后重绘」用的超分模型。**枚举名即服务端白名单键**
/// (`anima_provider._ANIMA_HIRES_UPSCALERS`),载荷直接发 [Enum.name],
/// 不认的键服务端兜底回 animesharp。
/// 三者的差异说明不在这儿:一律进「超分模型」那条参数说明(Help.hiresModel),
/// 免得卡片上再挂一行副标题。
enum HiresUpscaler {
  animesharp('AnimeSharp'),
  ultrasharp('UltraSharp'),
  anime6b('Anime 6B');

  const HiresUpscaler(this.label);

  final String label;
}

/// 二段步数下限:服务端 `max(4, min(50, steps))`。0 是「跟随主步数」的哨兵,
/// 不受此限;1~3 会被服务端悄悄抬到 4,故在 app 侧就钳住,免得读数骗人。
const kHiresStepsMin = 4;
const kHiresStepsMax = 50;

/// 重绘放大(hires two-pass):一段小图定构图 → 像素放大 → 低 denoise
/// 二段采样补细节。服务端 `_patch_anima_payload` 据此注入 320+ 节点链。
/// 各项取值范围与服务端钳制一致(scale 1.1~2.0 / denoise 0.2~0.75)。
class HiresConfig {
  const HiresConfig({
    this.enabled = false,
    this.scale = 1.5,
    this.denoise = 0.5,
    this.steps = 0,
    this.useModel = true,
    this.model = HiresUpscaler.animesharp,
  });

  final bool enabled;
  final double scale;
  final double denoise;

  /// 二段步数;0 = 跟随主步数(服务端读一段 KSampler 的 steps)。
  final int steps;

  /// true = 先超分后重绘(走 [model]);false = 直接重绘(lanczos 插值)。
  /// 与 [model] 分开存是为了来回切不丢用户选过的超分模型(对齐 web)。
  final bool useModel;
  final HiresUpscaler model;

  /// 载荷 `upscaler` 键:直接重绘发 `lanczos`,否则发超分模型键。
  String get upscalerKey => useModel ? model.name : 'lanczos';

  /// 二段目标尺寸,算法照抄服务端 `max(8, int(base * scale) // 8 * 8)`。
  (int, int) targetSize(int width, int height) =>
      (_align8(width * scale), _align8(height * scale));

  static int _align8(double v) {
    final n = v.toInt() ~/ 8 * 8;
    return n < 8 ? 8 : n;
  }

  HiresConfig copyWith({
    bool? enabled,
    double? scale,
    double? denoise,
    int? steps,
    bool? useModel,
    HiresUpscaler? model,
  }) => HiresConfig(
    enabled: enabled ?? this.enabled,
    scale: scale ?? this.scale,
    denoise: denoise ?? this.denoise,
    steps: steps ?? this.steps,
    useModel: useModel ?? this.useModel,
    model: model ?? this.model,
  );
}

const samplers = <String>[
  'Euler Ancestral',
  'Euler',
  'DPM++ 2S A',
  'DPM++ 2M SDE',
  'DPM++ 2M',
  'DPM++ SDE',
];

const noiseSchedules = <String>['karras', 'exponential', 'polyexponential'];

class GenParams {
  const GenParams({
    this.model = 'NAI 4.5 Full',
    this.width = 832,
    this.height = 1216,
    this.steps = 28,
    this.cfg = 5.0,
    this.varietyPlus = false,
    this.sampler = 'Euler Ancestral',
    this.noiseSchedule = 'karras',
    this.seed = '',
    this.cfgRescale = 0.0,
    this.normalizeVibe = true,
    this.loop = LoopCount.x8,
    this.animaSteps = 12,
    this.animaCfg = 1.0,
    this.animaSampler = 'euler',
    this.animaScheduler = 'simple',
    this.hires = const HiresConfig(),
  });

  final String model;
  final int width;
  final int height;
  final int steps;
  final double cfg;
  final bool varietyPlus;
  final String sampler;
  final String noiseSchedule;
  final String seed;
  final double cfgRescale;

  /// 多张 Vibe 时把强度按比例缩到合计 ≤1(关掉则各自独立相加)。
  final bool normalizeVibe;
  final LoopCount loop;

  // Anima 专属采样参数(与 NAI 的 steps/cfg/sampler 独立,两套不混用)。
  final int animaSteps;
  final double animaCfg;
  final String animaSampler;
  final String animaScheduler;

  /// 重绘放大(anima 专属模块;非 anima 或模块隐藏时由剥离层置 enabled=false)。
  final HiresConfig hires;

  /// Opus 免费判定(像素 ≤ 免费阈值 + ≤28 步),按像素而非预设成员,兼容自定义尺寸。
  bool get isFree => steps <= 28 && width * height <= kFreePixelThreshold;

  GenParams copyWith({
    String? model,
    int? width,
    int? height,
    int? steps,
    double? cfg,
    bool? varietyPlus,
    String? sampler,
    String? noiseSchedule,
    String? seed,
    double? cfgRescale,
    bool? normalizeVibe,
    LoopCount? loop,
    int? animaSteps,
    double? animaCfg,
    String? animaSampler,
    String? animaScheduler,
    HiresConfig? hires,
  }) {
    return GenParams(
      model: model ?? this.model,
      width: width ?? this.width,
      height: height ?? this.height,
      steps: steps ?? this.steps,
      cfg: cfg ?? this.cfg,
      varietyPlus: varietyPlus ?? this.varietyPlus,
      sampler: sampler ?? this.sampler,
      noiseSchedule: noiseSchedule ?? this.noiseSchedule,
      seed: seed ?? this.seed,
      cfgRescale: cfgRescale ?? this.cfgRescale,
      normalizeVibe: normalizeVibe ?? this.normalizeVibe,
      loop: loop ?? this.loop,
      animaSteps: animaSteps ?? this.animaSteps,
      animaCfg: animaCfg ?? this.animaCfg,
      animaSampler: animaSampler ?? this.animaSampler,
      animaScheduler: animaScheduler ?? this.animaScheduler,
      hires: hires ?? this.hires,
    );
  }
}

/// 折叠面板标识
enum Panel { prompt, characters, vibe, charRef, i2i, lora, hires, animaNl }

class GenerateState {
  const GenerateState({
    required this.prompt,
    required this.negativePrompt,
    this.promptRaw = '',
    this.negativePromptRaw = '',
    required this.characters,
    required this.vibes,
    required this.charRefs,
    required this.img2img,
    required this.params,
    required this.anlas,
    required this.openPanels,
    this.loras = const [],
    this.inpaint,
  });

  factory GenerateState.initial() => const GenerateState(
    prompt: '',
    negativePrompt: '',
    characters: [],
    vibes: [], // 真实 Vibe:用户选图后才有
    charRefs: [],
    img2img: null,
    params: GenParams(),
    anlas: 8420,
    openPanels: {},
  );

  final String prompt;
  final String negativePrompt;

  /// 编辑器原文草稿(含禁用/折叠等仅编辑期语法),空 = 与定稿无差别。
  /// [prompt] 恒为定稿:发给 NAI 的、算 token 的、拼预设的都只看它,
  /// 草稿不参与生成链路的任何一环。有效性判定见 [pickEditorText]。
  final String promptRaw;
  final String negativePromptRaw;

  final List<CharacterPrompt> characters;
  final List<VibeItem> vibes;
  final List<CharRefItem> charRefs;
  final Img2ImgConfig? img2img;
  final GenParams params;
  final int anlas;
  final Set<Panel> openPanels;

  /// 挂载的 LoRA(anima 专属;非 anima 模型生成时由模块剥离层清掉)。
  final List<ActiveLora> loras;

  /// 重绘任务载荷:仅由重绘编辑器写入生成快照(与 img2img 互斥,
  /// 优先生效);创作页编辑器状态恒为 null。
  final InpaintJob? inpaint;

  /// 粗略 token 估算(占位;正式版接 T5 分词)
  int get promptTokens => (prompt.length / 2.2).round().clamp(0, 999);
  int get negativeTokens => (negativePrompt.length / 2.2).round().clamp(0, 999);

  int get enabledVibes => vibes.where((v) => v.enabled).length;
  int get enabledCharRefs => charRefs.where((r) => r.enabled).length;
  int get enabledLoras => loras.where((l) => l.enabled).length;

  GenerateState copyWith({
    String? prompt,
    String? negativePrompt,
    String? promptRaw,
    String? negativePromptRaw,
    List<CharacterPrompt>? characters,
    List<VibeItem>? vibes,
    List<CharRefItem>? charRefs,
    Object? img2img = _unset,
    GenParams? params,
    int? anlas,
    Set<Panel>? openPanels,
    List<ActiveLora>? loras,
    Object? inpaint = _unset,
  }) {
    return GenerateState(
      prompt: prompt ?? this.prompt,
      negativePrompt: negativePrompt ?? this.negativePrompt,
      promptRaw: promptRaw ?? this.promptRaw,
      negativePromptRaw: negativePromptRaw ?? this.negativePromptRaw,
      characters: characters ?? this.characters,
      vibes: vibes ?? this.vibes,
      charRefs: charRefs ?? this.charRefs,
      img2img: img2img == _unset ? this.img2img : img2img as Img2ImgConfig?,
      params: params ?? this.params,
      anlas: anlas ?? this.anlas,
      openPanels: openPanels ?? this.openPanels,
      loras: loras ?? this.loras,
      inpaint: inpaint == _unset ? this.inpaint : inpaint as InpaintJob?,
    );
  }
}
