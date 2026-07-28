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
    this.abnormalThreshold = 10,
  });

  /// 正文字号可选档位。
  static const fontSizes = [14.0, 16.0, 18.0];

  /// 权重数值加减可选步进。
  static const weightSteps = [0.05, 0.1, 0.2, 0.5];

  /// 异常权重阈值可选档位。
  static const abnormalThresholds = [3.0, 5.0, 10.0];

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

  /// 词条栏 +/− 每步的数值调整量(0.05 / 0.1)。
  final double weightStep;

  /// 编辑器正文字号(14 / 16 / 18),注音测量层同步。
  final double fontSize;

  /// 异常权重阈值:词条中段 `N::` 的 N ≥ 此值视为疑似丢逗号(标红警示)。
  final double abnormalThreshold;

  EditorSettings copyWith({
    bool? showTranslation,
    bool? showWeightWash,
    bool? enableCompletion,
    bool? enableTagPanel,
    bool? autoComma,
    bool? entitySuggest,
    double? weightStep,
    double? fontSize,
    double? abnormalThreshold,
  }) => EditorSettings(
    showTranslation: showTranslation ?? this.showTranslation,
    showWeightWash: showWeightWash ?? this.showWeightWash,
    enableCompletion: enableCompletion ?? this.enableCompletion,
    enableTagPanel: enableTagPanel ?? this.enableTagPanel,
    autoComma: autoComma ?? this.autoComma,
    entitySuggest: entitySuggest ?? this.entitySuggest,
    weightStep: weightStep ?? this.weightStep,
    fontSize: fontSize ?? this.fontSize,
    abnormalThreshold: abnormalThreshold ?? this.abnormalThreshold,
  );

  /// 读回的数值不在档位表里(旧版本/脏数据)时回退默认。
  static double _snap(double? v, List<double> allowed, double fallback) {
    if (v == null) return fallback;
    for (final a in allowed) {
      if ((v - a).abs() < 0.001) return a;
    }
    return fallback;
  }

  factory EditorSettings.fromJson(Map<String, dynamic> j) => EditorSettings(
    showTranslation: j['showTranslation'] as bool? ?? true,
    showWeightWash: j['showWeightWash'] as bool? ?? true,
    enableCompletion: j['enableCompletion'] as bool? ?? true,
    enableTagPanel: j['enableTagPanel'] as bool? ?? true,
    autoComma: j['autoComma'] as bool? ?? true,
    entitySuggest: j['entitySuggest'] as bool? ?? true,
    weightStep: _snap((j['weightStep'] as num?)?.toDouble(), weightSteps, 0.1),
    fontSize: _snap((j['fontSize'] as num?)?.toDouble(), fontSizes, 16),
    abnormalThreshold: _snap(
      (j['abnormalThreshold'] as num?)?.toDouble(),
      abnormalThresholds,
      10,
    ),
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
    'abnormalThreshold': abnormalThreshold,
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
      other.abnormalThreshold == abnormalThreshold;

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
    abnormalThreshold,
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
