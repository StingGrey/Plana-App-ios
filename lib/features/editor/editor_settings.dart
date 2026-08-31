import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/store/prefs_store.dart';

/// 编辑器行为开关(持久化),默认全开。
class EditorSettings {
  const EditorSettings({
    this.showTranslation = true,
    this.showWeightWash = true,
    this.enableCompletion = true,
    this.enableTagPanel = true,
    this.autoComma = true,
    this.entitySuggest = true,
    this.weightStep = 0.1,
    this.fontSize = 16,
    this.chipFontSize = 16,
    this.chipMode = false,
    this.compactTagPanel = false,
  });

  /// 字号的可调范围与步长(正文与芯片共用这套界限,各自独立取值)。
  ///
  /// 原来是「小/标准/大」三档 —— 屏幕尺寸、视力、单双手各不相同,三档太粗。
  /// 上下界是排版能扛住的范围:再小注音那行糊成一片,再大一行放不下两个词。
  static const fontSizeMin = 10.0;
  static const fontSizeMax = 32.0;
  static const fontSizeStep = 1.0;

  /// 权重步进本身的可调范围与步长(即「每按一下 +/− 改多少」这个量)。
  ///
  /// 上界 1.0:一步一整倍已经是「按一下就翻番」,再大没有实用意义;
  /// 下界 0.01 = 读数的最小分辨率,再细也显示不出来。
  static const weightStepMin = 0.01;
  static const weightStepMax = 1.0;
  static const weightStepTick = 0.01;

  /// 词条下方的中文注音翻译层(关掉同时取消为译文预留的词间距/行高)。
  final bool showTranslation;

  /// 正文权重底色层(加权/降权按强度铺色 + 异常标红 + SD 提示);关掉=纯文本。
  final bool showWeightWash;

  /// 打字时的底部补全建议(补全条 + 分类弹层)。
  final bool enableCompletion;

  /// 光标停在词条上时的词条操作栏(权重 / 禁用 / 关联)。
  final bool enableTagPanel;

  /// 选中补全后自动在词尾补「, 」以便连打下一枚。
  final bool autoComma;

  /// 补全结果里是否出现实体建议(画师 / 角色 / OC / 作品),关=只留标签。
  final bool entitySuggest;

  /// 词条栏 +/− 每步的数值调整量,见 [weightStepMin] / [weightStepMax]。
  final double weightStep;

  /// 注音富文本的正文字号,见 [fontSizeMin] / [fontSizeMax];注音测量层同步。
  final double fontSize;

  /// 芯片模式的标签字号:chip 的内边距、译文行、图标全按它缩放。
  ///
  /// 与正文字号分开调:一个决定一屏能塞下多少字,一个决定点得准不准 ——
  /// 同一个人在两种形态下想要的往往不是同一档。
  final double chipFontSize;

  /// 正文的显示形态:false=注音富文本(默认),true=芯片流。
  /// 底栏一键切,记在设置里 —— 这是用惯了哪种的问题,不该每次进页面重选。
  final bool chipMode;

  /// 词条栏的形态:false=三行完整版(默认),true=一行精简版。
  ///
  /// 精简版只留**权重相关的全部功能**(括号 / 数值加减 / 清除)加删除与关闭,
  /// 名字、热度、译文、维基、复制、改名、禁用、关联全部收走 —— 换来的是
  /// 词条栏从一百多高压到四十几,正文能多露两行。同 chipMode,是用惯了哪种
  /// 的问题,所以记在设置里而不是每次重选。
  final bool compactTagPanel;

  EditorSettings copyWith({
    bool? showTranslation,
    bool? showWeightWash,
    bool? enableCompletion,
    bool? enableTagPanel,
    bool? autoComma,
    bool? entitySuggest,
    double? weightStep,
    double? fontSize,
    double? chipFontSize,
    bool? chipMode,
    bool? compactTagPanel,
  }) => EditorSettings(
    showTranslation: showTranslation ?? this.showTranslation,
    showWeightWash: showWeightWash ?? this.showWeightWash,
    enableCompletion: enableCompletion ?? this.enableCompletion,
    enableTagPanel: enableTagPanel ?? this.enableTagPanel,
    autoComma: autoComma ?? this.autoComma,
    entitySuggest: entitySuggest ?? this.entitySuggest,
    weightStep: weightStep ?? this.weightStep,
    fontSize: fontSize ?? this.fontSize,
    chipFontSize: chipFontSize ?? this.chipFontSize,
    chipMode: chipMode ?? this.chipMode,
    compactTagPanel: compactTagPanel ?? this.compactTagPanel,
  );

  /// 读回的数值夹回合法区间。缺省/NaN 回退默认 —— 越界(改小了上下界、
  /// 或者脏数据)夹住就好,不必把用户调过的偏好整个丢回默认。
  static double _range(double? v, double lo, double hi, double fallback) {
    if (v == null || v.isNaN) return fallback;
    return v.clamp(lo, hi).toDouble();
  }

  factory EditorSettings.fromJson(Map<String, dynamic> j) => EditorSettings(
    showTranslation: j['showTranslation'] as bool? ?? true,
    showWeightWash: j['showWeightWash'] as bool? ?? true,
    enableCompletion: j['enableCompletion'] as bool? ?? true,
    enableTagPanel: j['enableTagPanel'] as bool? ?? true,
    autoComma: j['autoComma'] as bool? ?? true,
    entitySuggest: j['entitySuggest'] as bool? ?? true,
    weightStep: _range(
      (j['weightStep'] as num?)?.toDouble(),
      weightStepMin,
      weightStepMax,
      0.1,
    ),
    fontSize: _range(
      (j['fontSize'] as num?)?.toDouble(),
      fontSizeMin,
      fontSizeMax,
      16,
    ),
    chipFontSize: _range(
      (j['chipFontSize'] as num?)?.toDouble(),
      fontSizeMin,
      fontSizeMax,
      // 旧档只有一个合并字号:芯片跟着它走,升级前后看着一样。
      _range((j['fontSize'] as num?)?.toDouble(), fontSizeMin, fontSizeMax, 16),
    ),
    chipMode: j['chipMode'] as bool? ?? false,
    compactTagPanel: j['compactTagPanel'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'showTranslation': showTranslation,
    'showWeightWash': showWeightWash,
    'enableCompletion': enableCompletion,
    'enableTagPanel': enableTagPanel,
    'autoComma': autoComma,
    'entitySuggest': entitySuggest,
    'weightStep': weightStep,
    'fontSize': fontSize,
    'chipFontSize': chipFontSize,
    'chipMode': chipMode,
    'compactTagPanel': compactTagPanel,
  };

  @override
  bool operator ==(Object other) =>
      other is EditorSettings &&
      other.showTranslation == showTranslation &&
      other.showWeightWash == showWeightWash &&
      other.enableCompletion == enableCompletion &&
      other.enableTagPanel == enableTagPanel &&
      other.autoComma == autoComma &&
      other.entitySuggest == entitySuggest &&
      other.weightStep == weightStep &&
      other.fontSize == fontSize &&
      other.chipFontSize == chipFontSize &&
      other.chipMode == chipMode &&
      other.compactTagPanel == compactTagPanel;

  @override
  int get hashCode => Object.hash(
    showTranslation,
    showWeightWash,
    enableCompletion,
    enableTagPanel,
    autoComma,
    entitySuggest,
    weightStep,
    fontSize,
    chipFontSize,
    chipMode,
    compactTagPanel,
  );
}

const _key = 'editor_settings';

final editorSettingsProvider =
    AsyncNotifierProvider<EditorSettingsNotifier, EditorSettings>(
      EditorSettingsNotifier.new,
    );

class EditorSettingsNotifier extends AsyncNotifier<EditorSettings> {
  PrefsStore get _storage => ref.read(prefsStoreProvider);

  @override
  Future<EditorSettings> build() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const EditorSettings();
      return EditorSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const EditorSettings();
    }
  }

  /// 先改状态(立即生效),再尽力持久化(失败不打断编辑)。
  Future<void> patch(EditorSettings Function(EditorSettings) change) async {
    final next = change(state.value ?? const EditorSettings());
    state = AsyncData(next);
    try {
      await _storage.write(key: _key, value: jsonEncode(next.toJson()));
    } catch (_) {}
  }
}
