import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/theme/theme_settings.dart';

void main() {
  test('外观设置 json 回环', () {
    const s = ThemeSettings(mode: ThemeMode.dark, seedKey: 'teal');
    expect(ThemeSettings.fromJson(s.toJson()), s);
  });

  test('脏数据回退默认(未知模式/未知色/类型错)', () {
    expect(
      ThemeSettings.fromJson({'mode': 'neon', 'seed': 'plaid'}),
      const ThemeSettings(),
    );
    expect(
      ThemeSettings.fromJson({'mode': 3, 'seed': 7}),
      const ThemeSettings(),
    );
    expect(ThemeSettings.fromJson({}), const ThemeSettings());
  });

  test('seed 找不到档位时回退第一档', () {
    expect(const ThemeSettings(seedKey: 'nope').seed.key, themeSeeds.first.key);
  });
}
