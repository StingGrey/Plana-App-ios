// 放大面板的参数记忆:选过一次之后,下次开面板要停在上次那档。
//
// 这条以前是坏的,坏在**读**那一侧:入口写的是
// `ref.read(upscaleSettingsProvider).value ?? const UpscaleSettings()`,
// 而它是懒加载的 AsyncNotifier —— 首读期间 `.value` 是 null,于是「还没读出来」
// 被当成了「没存过」,本次会话第一次开面板永远回默认档。写那侧一直是好的,
// 所以这类错只在真机上、只在第一次开面板时露头,单看代码很容易放过去。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/upscale_model.dart';

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('plana_upscale_mem');
  addTearDown(() async {
    for (var i = 0; i < 10; i++) {
      try {
        root.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  return root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 同一个盘,两次「开 app」。
  Future<ProviderContainer> boot(Directory root) async {
    final stores = await AppStores.open(rootOverride: root);
    final c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(() async {
      c.dispose();
      stores.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    return c;
  }

  test('选过的方式与倍率下次还在', () async {
    final root = _tempRoot();

    final a = await boot(root);
    await a.read(upscaleSettingsProvider.future);
    await a
        .read(upscaleSettingsProvider.notifier)
        .set(
          const UpscaleSettings(
            method: UpscaleMethod.redraw,
            enhanceScale: EnhanceScale.max,
            strength: 0.35,
            noise: 0.12,
          ),
        );

    // 重开:**await future 而不是取 .value** —— 后者在首读期间是 null,
    // 正是这条 bug 的成因,所以这里必须按入口现在的写法来验。
    final b = await boot(root);
    final s = await b.read(upscaleSettingsProvider.future);
    expect(s.method, UpscaleMethod.redraw);
    expect(s.enhanceScale, EnhanceScale.max);
    expect(s.strength, 0.35);
    expect(s.noise, 0.12);
  });

  // 首读那一刻 .value 还是 null —— 这就是「没记住」的现场。入口按 .value 取会
  // 拿到默认档,await 才能拿到存档。
  test('首读期间 .value 是 null,await 才有值', () async {
    final root = _tempRoot();

    final a = await boot(root);
    await a.read(upscaleSettingsProvider.future);
    await a
        .read(upscaleSettingsProvider.notifier)
        .set(const UpscaleSettings(method: UpscaleMethod.redraw));

    final b = await boot(root);
    expect(b.read(upscaleSettingsProvider).value, isNull); // 还没读出来
    expect(
      (await b.read(upscaleSettingsProvider.future)).method,
      UpscaleMethod.redraw,
    );
  });
}
