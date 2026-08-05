/// 导入的模型类别路由 —— 与 web `utils/importOptions.ts` 同构。
///
/// Anima 的后端就是 Modal 上的 ComfyUI,出图参数(sampler `euler`、scheduler `simple`…)
/// 就是 ComfyUI 的原生取值,所以 **ComfyUI 图 ≡ Anima 类别**,两者参数 1:1 落;
/// 往 NovelAI 上落才是有损映射。
///
/// 规则:图的类别 == 当前模型类别 → 完整解析、全字段可导;
/// 跨类别 → 只导正/负向提示词,并给一个「切换到 xx 模型」的按钮,切过去再完整解析。
library;

import '../generate/models.dart'
    show
        animaCfgRange,
        animaSamplers,
        animaSchedulers,
        animaStepsRange,
        isAnimaModel;
import 'image_metadata.dart';

enum ModelCategory { nai, comfy }

String categoryLabel(ModelCategory c) =>
    c == ModelCategory.comfy ? 'Anima' : 'NovelAI';

/// 当前选中的模型属于哪个类别。
ModelCategory categoryOfModel(String displayModel) =>
    isAnimaModel(displayModel) ? ModelCategory.comfy : ModelCategory.nai;

/// 图属于哪个模型类别。SD/未知来源没有对应的本机模型,返回 null。
ModelCategory? categoryOfImage(ImageMetadata? meta) => switch (meta?.sourceType) {
  ImageSourceType.novelai => ModelCategory.nai,
  ImageSourceType.comfyui => ModelCategory.comfy,
  _ => null,
};

/// 图和当前模型不是一个类别(含「图没有对应类别」)时,只允许导提示词。
bool isCrossCategory(ImageMetadata? meta, ModelCategory target) =>
    categoryOfImage(meta) != target;

/// 导入这段提示词到目标类别时要不要转换权重语法。
///
/// 编辑器里存的始终是 NAI 语法:发 NovelAI 原样送,发 Anima 由服务端翻成 ComfyUI 语法
/// (已是 Comfy 格式的原样放行)。所以只有「源是 a1111 语法、要进 NovelAI」才需要转。
bool needsPromptConversion(ImageMetadata? meta, ModelCategory target) =>
    meta?.promptSyntax == PromptSyntax.a1111 && target == ModelCategory.nai;

/// ComfyUI 图的模型文件名 → Anima 档位展示名。
/// 前缀严格匹配,避免 `sd_xl_base_1.0` 被当成 base 档。
String? animaModelFromSource(String? source) {
  if (source == null) return null;
  final s = source.toLowerCase();
  if (s.startsWith('anima-turbo')) return 'Anima Turbo';
  if (s.startsWith('anima-aesthetic')) return 'Anima Aesthetic';
  if (s.startsWith('anima-base')) return 'Anima Base';
  return null;
}

/// Anima 采样器 id → 展示名;不在白名单返回 null。
String? animaSamplerLabel(String? id) {
  for (final o in animaSamplers) {
    if (o.id == id) return o.label;
  }
  return null;
}

/// Anima 调度器 id → 展示名;不在白名单返回 null。
String? animaSchedulerLabel(String? id) {
  for (final o in animaSchedulers) {
    if (o.id == id) return o.label;
  }
  return null;
}

/// 步数是否在本机支持范围内。
bool animaStepsSupported(int v) =>
    v >= animaStepsRange.min && v <= animaStepsRange.max;

/// CFG 是否在本机支持范围内。
bool animaCfgSupported(double v) =>
    v >= animaCfgRange.min && v <= animaCfgRange.max;
