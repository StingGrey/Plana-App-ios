import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/secure_storage.dart';

/// 主题色档位。
class ThemeSeed {
  const ThemeSeed(this.key, this.label, this.color);

  final String key;
  final String label;
  final Color color;
}

// 按色环排列(新增档位只管加,持久化按 key 不受顺序影响)。
const themeSeeds = <ThemeSeed>[
  ThemeSeed('gold', '金', Color(0xFFD4A72C)),
  ThemeSeed('orange', '橙', Color(0xFFEF6C00)),
  ThemeSeed('red', '红', Color(0xFFC62828)),
  ThemeSeed('rose', '粉', Color(0xFFD81B60)),
  ThemeSeed('plum', '梅', Color(0xFF8E24AA)),
  ThemeSeed('violet', '紫', Color(0xFF6750A4)),
  ThemeSeed('indigo', '靛', Color(0xFF3949AB)),
  ThemeSeed('blue', '蓝', Color(0xFF1E88E5)),
  ThemeSeed('teal', '青', Color(0xFF00897B)),
  ThemeSeed('green', '绿', Color(0xFF2E7D32)),
  ThemeSeed('brown', '棕', Color(0xFF795548)),
  ThemeSeed('grey', '灰', Color(0xFF607D8B)),
];

/// 外观设置(持久化):深浅模式 + 主题色。
class ThemeSettings {
  const ThemeSettings({this.mode = ThemeMode.light, this.seedKey = 'gold'});

  final ThemeMode mode;
  final String seedKey;

  ThemeSeed get seed => themeSeeds.firstWhere(
        (s) => s.key == seedKey,
        orElse: () => themeSeeds.first,
      );

  ThemeSettings copyWith({ThemeMode? mode, String? seedKey}) =>
      ThemeSettings(mode: mode ?? this.mode, seedKey: seedKey ?? this.seedKey);

  /// 脏数据(旧版本/未知档位)回退默认。
  factory ThemeSettings.fromJson(Map<String, dynamic> j) => ThemeSettings(
        mode: ThemeMode.values.asNameMap()[j['mode']] ?? ThemeMode.light,
        seedKey: themeSeeds.any((s) => s.key == j['seed'])
            ? j['seed'] as String
            : 'gold',
      );

  Map<String, dynamic> toJson() => {'mode': mode.name, 'seed': seedKey};

  @override
  bool operator ==(Object other) =>
      other is ThemeSettings && other.mode == mode && other.seedKey == seedKey;

  @override
  int get hashCode => Object.hash(mode, seedKey);
}

const _key = 'theme_settings';

/// 启动时预读的初始值(main 注入,首帧即为用户配色,不闪变)。
final themeInitProvider =
    Provider<ThemeSettings>((_) => const ThemeSettings());

Future<ThemeSettings> loadThemeSettings() async {
  try {
    final raw = await const FlutterSecureStorage().read(key: _key);
    if (raw == null || raw.isEmpty) return const ThemeSettings();
    return ThemeSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return const ThemeSettings();
  }
}

final themeSettingsProvider =
    NotifierProvider<ThemeSettingsNotifier, ThemeSettings>(
  ThemeSettingsNotifier.new,
);

class ThemeSettingsNotifier extends Notifier<ThemeSettings> {
  @override
  ThemeSettings build() => ref.watch(themeInitProvider);

  /// 先改状态(全局即时换肤),再尽力持久化。
  void patch(ThemeSettings Function(ThemeSettings) change) {
    state = change(state);
    _persist(state);
  }

  Future<void> _persist(ThemeSettings s) async {
    try {
      await ref
          .read(secureStorageProvider)
          .write(key: _key, value: jsonEncode(s.toJson()));
    } catch (_) {}
  }
}
