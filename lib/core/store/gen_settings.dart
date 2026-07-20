import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/secure_storage.dart';

/// 生成设置(持久化)。
/// [retryOn429]:被限流(HTTP 429)时自动重试当张,默认开;
/// 固定间隔 [retryDelaySecs] 秒(0 = 立即),最多 [retryCount] 次。
class GenSettings {
  const GenSettings({
    this.retryOn429 = true,
    this.retryDelaySecs = 1,
    this.retryCount = 3,
  });

  final bool retryOn429;
  final int retryDelaySecs;
  final int retryCount;

  GenSettings copyWith({
    bool? retryOn429,
    int? retryDelaySecs,
    int? retryCount,
  }) =>
      GenSettings(
        retryOn429: retryOn429 ?? this.retryOn429,
        retryDelaySecs: retryDelaySecs ?? this.retryDelaySecs,
        retryCount: retryCount ?? this.retryCount,
      );

  static int _intIn(Object? v, int fallback, int min, int max) {
    final n = (v as num?)?.toInt() ?? fallback;
    return n.clamp(min, max);
  }

  factory GenSettings.fromJson(Map<String, dynamic> j) => GenSettings(
        retryOn429: j['retryOn429'] is bool ? j['retryOn429'] as bool : true,
        retryDelaySecs: _intIn(j['retryDelaySecs'], 1, 0, 600),
        retryCount: _intIn(j['retryCount'], 3, 1, 99),
      );

  Map<String, dynamic> toJson() => {
        'retryOn429': retryOn429,
        'retryDelaySecs': retryDelaySecs,
        'retryCount': retryCount,
      };

  @override
  bool operator ==(Object other) =>
      other is GenSettings &&
      other.retryOn429 == retryOn429 &&
      other.retryDelaySecs == retryDelaySecs &&
      other.retryCount == retryCount;

  @override
  int get hashCode => Object.hash(retryOn429, retryDelaySecs, retryCount);
}

const _key = 'gen_settings';

final genSettingsProvider =
    AsyncNotifierProvider<GenSettingsNotifier, GenSettings>(
  GenSettingsNotifier.new,
);

class GenSettingsNotifier extends AsyncNotifier<GenSettings> {
  @override
  Future<GenSettings> build() async {
    try {
      final raw = await ref.read(secureStorageProvider).read(key: _key);
      if (raw == null || raw.isEmpty) return const GenSettings();
      return GenSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const GenSettings();
    }
  }

  /// 先改状态(立即生效),再尽力持久化。
  Future<void> patch(GenSettings Function(GenSettings) change) async {
    final next = change(state.value ?? const GenSettings());
    state = AsyncData(next);
    try {
      await ref
          .read(secureStorageProvider)
          .write(key: _key, value: jsonEncode(next.toJson()));
    } catch (_) {}
  }
}
