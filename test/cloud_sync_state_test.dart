import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/platform/cloud_folder.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/cloud_sync/cloud_sync_state.dart';

/// 「选完 iCloud Drive 文件夹没有任何反应」:选择流程的每个出口都要给界面
/// 一个明确结果 —— 选中、取消,或者带原因的错误。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(cloudFolderChannelName);
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  late Directory root;
  late List<String> calls;
  late Object? Function(MethodCall call) native;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    root = Directory.systemTemp.createTempSync('cloud_sync_state_');
    calls = [];
    native = (call) => switch (call.method) {
      'status' => {'configured': false, 'available': false},
      'list' => <Object?>[],
      _ => null,
    };
    messenger.setMockMethodCallHandler(pathProvider, (_) async => root.path);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return native(call);
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(pathProvider, null);
    messenger.setMockMethodCallHandler(channel, null);
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue, reason: '等不到预期状态');
  }

  Future<ProviderContainer> open() async {
    final c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(AppStores.ephemeral())],
    );
    addTearDown(c.dispose);
    c.read(cloudSyncProvider);
    await until(() => c.read(cloudSyncProvider).folder != null);
    return c;
  }

  test('选中文件夹后记住它并马上同步一轮', () async {
    native = (call) => switch (call.method) {
      'status' => {'configured': false, 'available': false},
      'pick' => {'configured': true, 'available': true, 'name': 'Plana'},
      'list' => <Object?>[],
      _ => null,
    };
    final c = await open();

    final picked = await c.read(cloudSyncProvider.notifier).pickFolder();

    expect(picked?.name, 'Plana');
    final s = c.read(cloudSyncProvider);
    expect(s.folder?.ready, isTrue);
    expect(s.folder?.name, 'Plana');
    expect(s.error, isNull);
    await until(() => calls.contains('list'));
    await until(() => c.read(cloudSyncProvider).lastSyncAt > 0);
  });

  test('取消选择不报错,也不改已有状态', () async {
    final c = await open();

    final picked = await c.read(cloudSyncProvider.notifier).pickFolder();

    expect(picked, isNull);
    final s = c.read(cloudSyncProvider);
    expect(s.folder?.configured, isFalse);
    expect(s.error, isNull);
    expect(calls, isNot(contains('list')));
  });

  test('原生报错时原因进 error,界面才有东西可提示', () async {
    native = (call) => switch (call.method) {
      'status' => {'configured': false, 'available': false},
      'pick' => throw PlatformException(
        code: 'present',
        message: '文件夹选择器没能弹出来，请再点一次',
      ),
      _ => null,
    };
    final c = await open();

    final picked = await c.read(cloudSyncProvider.notifier).pickFolder();

    expect(picked, isNull);
    expect(c.read(cloudSyncProvider).error, '文件夹选择器没能弹出来，请再点一次');
  });

  test('上一次的错误不会在这次取消后又冒出来', () async {
    var fail = true;
    native = (call) => switch (call.method) {
      'status' => {'configured': false, 'available': false},
      'pick' when fail => throw PlatformException(code: 'busy', message: '忙'),
      _ => null,
    };
    final c = await open();
    final notifier = c.read(cloudSyncProvider.notifier);
    await notifier.pickFolder();
    expect(c.read(cloudSyncProvider).error, '忙');

    fail = false;
    await notifier.pickFolder();

    expect(c.read(cloudSyncProvider).error, isNull);
  });

  test('选中的文件夹打不开时提示重新选,不去同步', () async {
    native = (call) => switch (call.method) {
      'status' => {'configured': false, 'available': false},
      'pick' => {'configured': true, 'available': false, 'name': 'Plana'},
      _ => null,
    };
    final c = await open();

    final picked = await c.read(cloudSyncProvider.notifier).pickFolder();

    expect(picked?.ready, isFalse);
    final s = c.read(cloudSyncProvider);
    expect(s.folder?.configured, isTrue);
    expect(s.error, isNotNull);
    expect(calls, isNot(contains('list')));
  });

  test('安装包缺原生桥时给出能看懂的提示,按钮照样能点', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final c = await open();

    expect(c.read(cloudSyncProvider).folder?.configured, isFalse);
    expect(c.read(cloudSyncProvider).error, contains('prepare_ios.sh'));

    final picked = await c.read(cloudSyncProvider.notifier).pickFolder();

    expect(picked, isNull);
    expect(c.read(cloudSyncProvider).error, contains('prepare_ios.sh'));
  });
}
