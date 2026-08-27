import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/gen_queue.dart';
import 'package:plana_app/features/generate/generate_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer() {
    final stores = AppStores.ephemeral();
    final c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(() async {
      c.dispose();
      // 排空工作台防抖落盘,避免残留 Timer 写已删目录
      stores.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    return c;
  }

  test('入队是快照:入队后改编辑器不影响已排任务', () {
    final c = makeContainer();
    c.read(generateProvider.notifier).setPrompts(positive: 'A');
    expect(c.read(genQueueProvider.notifier).enqueue(), isTrue);
    c.read(generateProvider.notifier).setPrompts(positive: 'B');

    expect(c.read(genQueueProvider).items.single.snapshot.prompt, 'A');
    expect(c.read(generateProvider).prompt, 'B');
  });

  test('容量上限:塞满后拒绝', () {
    final c = makeContainer();
    final n = c.read(genQueueProvider.notifier);
    for (var i = 0; i < GenQueueNotifier.cap; i++) {
      expect(n.enqueue(), isTrue);
    }
    expect(n.enqueue(), isFalse);
    expect(c.read(genQueueProvider).items, hasLength(GenQueueNotifier.cap));
  });

  test('删除指定项与清空,顺序保持', () {
    final c = makeContainer();
    final n = c.read(genQueueProvider.notifier);
    n.enqueue();
    n.enqueue();
    n.enqueue();
    final ids = [for (final t in c.read(genQueueProvider).items) t.id];
    n.remove(ids[1]);
    expect(
      [for (final t in c.read(genQueueProvider).items) t.id],
      [ids[0], ids[2]],
    );
    n.clear();
    expect(c.read(genQueueProvider).items, isEmpty);
  });
}
