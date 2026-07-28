import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/app_info.dart';

/// 关于页展示的版本号是写死的常量(不引 package_info 插件)。
/// 它和 pubspec 一旦对不上,用户看到的就是个假版本号 —— 这里钉死。
void main() {
  test('kAppVersion / kAppBuild 与 pubspec.yaml 一致', () {
    final line = File(
      'pubspec.yaml',
    ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.trim(), 'version: $kAppVersion+$kAppBuild');
  });
}
