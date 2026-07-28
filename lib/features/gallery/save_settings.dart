import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';

/// 保存到相册的元数据处理方式(对齐 web SaveModal)。
enum SaveMeta { original, clean, custom }

enum SaveFormat { png, jpg }

/// 图库的默认保存设置(持久化):点「保存」直接按此存相册,
/// 长按进保存设置面板可单次调整或改默认。
class SaveSettings {
  const SaveSettings({
    this.meta = SaveMeta.original,
    this.format = SaveFormat.png,
    this.quality = 0.92,
    this.customPrompt = '',
  });

  final SaveMeta meta;
  final SaveFormat format;

  /// JPG 压缩质量 0.1~1.0。
  final double quality;

  /// meta = custom 时写入的提示词。
  final String customPrompt;

  SaveSettings copyWith({
    SaveMeta? meta,
    SaveFormat? format,
    double? quality,
    String? customPrompt,
  }) => SaveSettings(
    meta: meta ?? this.meta,
    format: format ?? this.format,
    quality: quality ?? this.quality,
    customPrompt: customPrompt ?? this.customPrompt,
  );

  factory SaveSettings.fromJson(Map<String, dynamic> j) {
    final q = (j['quality'] as num?)?.toDouble() ?? 0.92;
    return SaveSettings(
      meta: SaveMeta.values.asNameMap()[j['meta']] ?? SaveMeta.original,
      format: SaveFormat.values.asNameMap()[j['format']] ?? SaveFormat.png,
      quality: q.clamp(0.1, 1.0),
      customPrompt: j['customPrompt'] is String
          ? j['customPrompt'] as String
          : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'meta': meta.name,
    'format': format.name,
    'quality': quality,
    'customPrompt': customPrompt,
  };

  @override
  bool operator ==(Object other) =>
      other is SaveSettings &&
      other.meta == meta &&
      other.format == format &&
      other.quality == quality &&
      other.customPrompt == customPrompt;

  @override
  int get hashCode => Object.hash(meta, format, quality, customPrompt);
}

const _key = 'save_settings';

final saveSettingsProvider =
    AsyncNotifierProvider<SaveSettingsNotifier, SaveSettings>(
      SaveSettingsNotifier.new,
    );

class SaveSettingsNotifier extends AsyncNotifier<SaveSettings> {
  @override
  Future<SaveSettings> build() async {
    try {
      final raw = await ref.read(prefsStoreProvider).read(key: _key);
      if (raw == null || raw.isEmpty) return const SaveSettings();
      return SaveSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const SaveSettings();
    }
  }

  /// 先改状态(立即生效),再尽力持久化。
  Future<void> patch(SaveSettings Function(SaveSettings) change) async {
    final next = change(state.value ?? const SaveSettings());
    state = AsyncData(next);
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _key, value: jsonEncode(next.toJson()));
    } catch (_) {}
  }
}
