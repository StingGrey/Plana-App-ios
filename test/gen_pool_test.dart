// 并行出图的任务池:并发闸门、画布跟随、逐条取消。
//
// 真出图要网络,这里只测不依赖网络的那半边:池的形状、并发上限怎么算、
// 提交失败时占位卡有没有收干净。上限那条尤其要守 —— 直连的并发是**按 Key 数**
// 算的(NAI 按账号限流,同一把 Key 并发只会自己打自己),写死成常数就等于
// 主动去踩 429。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/token_store.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/generation_controller.dart';

GenJob _job(String id, {int seq = 0, GenJobKind kind = GenJobKind.normal}) =>
    GenJob(
      id: id,
      kind: kind,
      stage: GenJobStage.running,
      width: 832,
      height: 1216,
      seq: seq,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer({
    AuthMode mode = AuthMode.token,
    List<String> keys = const [],
  }) {
    final stores = AppStores.ephemeral();
    final c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        authModeProvider.overrideWith(() => _FakeAuthMode(mode)),
        naiKeysProvider.overrideWith((ref) async => keys),
      ],
    );
    addTearDown(() async {
      c.dispose();
      stores.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    return c;
  }

  test('池:新的排最前,选中跟着 id 走', () {
    const pool = GenPool(jobs: [], selectedId: null);
    expect(pool.busy, isFalse);
    expect(pool.selected, isNull);

    final p2 = pool.copyWith(
      jobs: [_job('a', seq: 1), _job('b', seq: 2)],
      selectedId: 'a',
    );
    // 展示顺序与图库一致:后提交的在前
    expect(p2.newestFirst.map((j) => j.id), ['b', 'a']);
    expect(p2.selected?.id, 'a');
    expect(p2.busy, isTrue);
    // 选中的那条跑完被摘掉 → 不再有跟随目标(画布该回成图/历史图)
    expect(p2.copyWith(jobs: [_job('b', seq: 2)]).selected, isNull);
    expect(p2.copyWith(clearSelected: true).selectedId, isNull);
  });

  test('进度只在出图阶段才有值', () {
    expect(_job('a').progress, isNull); // step=0:还没出图,走不确定动画
    expect(_job('a').copyWith(step: 7, total: 28).progress, .25);
    expect(_job('a').copyWith(step: 99, total: 28).progress, 1.0); // 钳到 1
  });

  test('bot 模式并发固定 5', () async {
    final c = makeContainer(mode: AuthMode.bot);
    expect(
      await c.read(generationProvider.notifier).concurrency(),
      kMaxRunningBot,
    );
  });

  test('直连并发 = 已存 Key 数(每条任务独占一把)', () async {
    // 今天只存一把 → 1,即直连仍是一次一张,与并行前行为一致
    final one = makeContainer(keys: ['pst-a']);
    expect(await one.read(generationProvider.notifier).concurrency(), 1);

    // 多 Key 落地后自动放大,不用改闸门
    final three = makeContainer(keys: ['pst-a', 'pst-b', 'pst-c']);
    expect(await three.read(generationProvider.notifier).concurrency(), 3);

    // 一把都没存也给 1:让它照常跑到「没有令牌」那个错误上,
    // 而不是卡在等位里没有下文
    final none = makeContainer();
    expect(await none.read(generationProvider.notifier).concurrency(), 1);
  });

  test('没有令牌:报错且占位卡收干净,不留幽灵', () async {
    final c = makeContainer();
    final n = c.read(generationProvider.notifier);
    expect(await n.generate(), GenOutcome.notCharged);
    final pool = c.read(generationProvider);
    expect(pool.jobs, isEmpty); // 建过卡就得摘掉
    expect(pool.noToken, isTrue); // 哨兵:创作页据此引导去设置
    // 兼容视图跟着回到 idle,并把错误透出去给全局提示
    expect(c.read(genStatusProvider).busy, isFalse);
    expect(c.read(genStatusProvider).noToken, isTrue);
  });

  test('画布跟随:select 切换,cancelJob 认不出的 id 不炸', () {
    final c = makeContainer();
    final n = c.read(generationProvider.notifier);
    n.select('nope'); // 池子空的时候也允许置位,selected 自然是 null
    expect(c.read(generationProvider).selectedId, 'nope');
    expect(c.read(generationProvider).selected, isNull);
    n.select(null);
    expect(c.read(generationProvider).selectedId, isNull);
    n.cancelJob('nope'); // 没有这条运行时:静默返回
  });

  test('重绘视图只认重绘那条', () {
    final c = makeContainer();
    // 普通任务不该让重绘面板以为自己在跑(否则面板会被后台出图带着收掉)
    expect(c.read(inpaintStatusProvider).busy, isFalse);
  });
}

class _FakeAuthMode extends AuthModeNotifier {
  _FakeAuthMode(this.mode);

  final AuthMode mode;

  @override
  Future<AuthMode?> build() async => mode;
}
