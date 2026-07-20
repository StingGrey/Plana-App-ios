import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/live_progress/live_progress.dart';
import 'gen_modules.dart';
import 'generate_state.dart';
import 'generation_controller.dart';
import 'loop_controller.dart';
import 'models.dart';

/// 排队任务:入队瞬间的完整参数快照,之后随便改编辑器不影响已排的。
class QueuedTask {
  const QueuedTask({required this.id, required this.snapshot});

  final int id;
  final GenerateState snapshot;
}

/// items 为待跑任务(不含正在跑的);active = 消费中;
/// done 为本轮已完成张数;stopping = 当前张跑完后暂停。
class GenQueueState {
  const GenQueueState({
    this.items = const [],
    this.active = false,
    this.done = 0,
    this.stopping = false,
  });

  final List<QueuedTask> items;
  final bool active;
  final int done;
  final bool stopping;

  int get batch => done + 1;
  int get total => done + 1 + items.length;

  GenQueueState copyWith({
    List<QueuedTask>? items,
    bool? active,
    int? done,
    bool? stopping,
  }) =>
      GenQueueState(
        items: items ?? this.items,
        active: active ?? this.active,
        done: done ?? this.done,
        stopping: stopping ?? this.stopping,
      );
}

final genQueueProvider = NotifierProvider<GenQueueNotifier, GenQueueState>(
  GenQueueNotifier.new,
);

/// 生成队列:生成中点排队把当前参数快照排进来,当前张/循环跑完自动顺序消费。
/// 消费间隙的手动生成可插队,成功后队列自动续。单张失败重试一次,仍失败
/// 放回队首并暂停(队列面板「继续」或下一次手动生成成功后恢复)。
/// 队列不落盘:与进行中的生成同属临时工作,重启即清。
class GenQueueNotifier extends Notifier<GenQueueState> {
  static const cap = 20;

  int _seq = 0;

  @override
  GenQueueState build() => const GenQueueState();

  bool get _appForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// 当前编辑器状态快照入队;满则拒绝。
  bool enqueue() {
    if (state.items.length >= cap) return false;
    // 与手动生成同语义:入队即按模块配置剥离,消费时不再看配置
    final snap = stripHiddenModules(
      ref.read(generateProvider),
      ref.read(genModulesProvider).value ?? const GenModuleSettings(),
    );
    state = state.copyWith(
      items: [...state.items, QueuedTask(id: _seq++, snapshot: snap)],
    );
    return true;
  }

  void remove(int id) {
    state = state.copyWith(
      items: [
        for (final t in state.items)
          if (t.id != id) t,
      ],
    );
  }

  void clear() {
    state = state.copyWith(items: const []);
  }

  /// 当前张跑完后暂停(不打断进行中的生成)。
  void stopAfterCurrent() {
    if (state.active) state = state.copyWith(stopping: true);
  }

  /// 空闲且有排队任务时开始消费;生成中/循环中让位,由对方收尾时再拉起。
  Future<void> maybeStart() async {
    if (state.active || state.items.isEmpty) return;
    if (ref.read(generationProvider).busy) return;
    if (ref.read(loopStatusProvider).active) return;
    await _drain();
  }

  Future<void> _drain() async {
    state = state.copyWith(active: true, done: 0, stopping: false);
    var ok = true;
    while (!state.stopping && state.items.isNotEmpty) {
      // 消费间隙用户手动点了生成:等它跑完再续
      if (ref.read(generationProvider).busy) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      final task = state.items.first;
      state = state.copyWith(items: state.items.sublist(1));
      final gen = ref.read(generationProvider.notifier);
      ok = await gen.generate(using: task.snapshot);
      if (!ok) ok = await gen.generate(using: task.snapshot); // 瞬时抖动重试一次
      if (!ok) {
        state = state.copyWith(items: [task, ...state.items]); // 放回队首
        break;
      }
      state = state.copyWith(done: state.done + 1);
    }
    final done = state.done;
    final left = state.items.length;
    state = GenQueueState(items: state.items);

    // 与循环同款收尾:前台静默撤通知;后台留一条汇总,可点回应用
    if (_appForeground) {
      await LiveProgress.instance.stop();
    } else {
      await LiveProgress.instance.finish(
        text: left == 0 ? '队列完成 · 共 $done 张' : '队列暂停 · 剩 $left 项',
      );
    }
  }
}
