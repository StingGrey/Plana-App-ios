import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/secure_storage.dart';

/// 存储上限设置(持久化):各仓库超出上限自动删最旧
/// (图库按入库顺序,库按最近使用)。上限由用户自由输入,0 = 无上限(默认)。
class StorageSettings {
  const StorageSettings({
    this.galleryCap = 0,
    this.vibeCap = 0,
    this.charRefCap = 0,
  });

  final int galleryCap;
  final int vibeCap;
  final int charRefCap;

  StorageSettings copyWith({int? galleryCap, int? vibeCap, int? charRefCap}) =>
      StorageSettings(
        galleryCap: galleryCap ?? this.galleryCap,
        vibeCap: vibeCap ?? this.vibeCap,
        charRefCap: charRefCap ?? this.charRefCap,
      );

  /// 脏数据(负数/非数字)回退无上限;上限封顶 999999。
  static int _nonNeg(Object? v) {
    final n = (v as num?)?.toInt() ?? 0;
    return n.clamp(0, 999999);
  }

  factory StorageSettings.fromJson(Map<String, dynamic> j) => StorageSettings(
        galleryCap: _nonNeg(j['galleryCap']),
        vibeCap: _nonNeg(j['vibeCap']),
        charRefCap: _nonNeg(j['charRefCap']),
      );

  Map<String, dynamic> toJson() => {
        'galleryCap': galleryCap,
        'vibeCap': vibeCap,
        'charRefCap': charRefCap,
      };

  @override
  bool operator ==(Object other) =>
      other is StorageSettings &&
      other.galleryCap == galleryCap &&
      other.vibeCap == vibeCap &&
      other.charRefCap == charRefCap;

  @override
  int get hashCode => Object.hash(galleryCap, vibeCap, charRefCap);
}

const _key = 'storage_settings';

final storageSettingsProvider =
    AsyncNotifierProvider<StorageSettingsNotifier, StorageSettings>(
  StorageSettingsNotifier.new,
);

class StorageSettingsNotifier extends AsyncNotifier<StorageSettings> {
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  @override
  Future<StorageSettings> build() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const StorageSettings();
      return StorageSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const StorageSettings();
    }
  }

  /// 先改状态(立即生效,各仓库监听后自动裁剪),再尽力持久化。
  Future<void> patch(StorageSettings Function(StorageSettings) change) async {
    final next = change(state.value ?? const StorageSettings());
    state = AsyncData(next);
    try {
      await _storage.write(key: _key, value: jsonEncode(next.toJson()));
    } catch (_) {}
  }
}
