import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/platform/platform_support.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android exposes foreground-service capabilities', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isIOSPlatform, isFalse);
    expect(supportsGenerationProgressNotifications, isTrue);
    expect(supportsBackgroundGeneration, isTrue);
    expect(supportsGithubReleaseUpdate, isTrue);
  });

  test('iOS uses foreground-only generation in the first port', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(isIOSPlatform, isTrue);
    expect(supportsGenerationProgressNotifications, isFalse);
    expect(supportsBackgroundGeneration, isFalse);
    expect(supportsGithubReleaseUpdate, isFalse);
  });
}
