import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/live_progress/live_progress.dart';
import 'gen_modules.dart';
import 'generate_state.dart';
import '../fixed_tags/fixed_tags.dart';
import 'generation_controller.dart';
import 'loop_controller.dart';
import 'models.dart';

/// 排队任务:入队瞬间的完整参数快照,之后随便改编辑器不影响已排的。
class QueuedTask {
  const QueuedTask({
    required this.id,
    required this.snapshot,
    this.fixedTags = const FixedTagsState(),
  });

  final int id;
  final GenerateState snapshot;

  /// Fixed prompt fragments are captured with the task, just like the rest of
  /// the generation settings. Changing the library after enqueueing must not
  /// silently change an already submitted task.
  final FixedTagsState fixedTags;
}

/// Failure behavior after the safe, no-charge retry has been exhausted.
enum QueueFailureMode { pause, skip }

extension QueueFailureModeX on QueueFailureMode {
  String get label => switch (this) {
    QueueFailureMode.pause => '失败后暂停',
    QueueFailureMode.skip => '跳过失败继续',
  };
}

/// A finished queue item kept for the management page. The generation pool is
/// deliberately transient, so this small history is the only way to explain
/// what happened after a queue run finishes.
class QueueHistoryEntry {
  const QueueHistoryEntry({
    required this.task,
    required this.outcome,
    required this.finishedAt,
    this.message,
  });

  final QueuedTask task;
  final GenOutcome outcome;
  final DateTime finishedAt;
  final String? message;

  bool get succeeded => outcome == GenOutcome.ok;
}

/// items 为待跑任务(不含正在跑的);active = 消费中;
/// done 为本轮已完成张数;stopping = 当前张跑完后暂停。
class GenQueueState {
  const GenQueueState({
    this.items = const [],
    this.active = false,
    this.done = 0,
    this.stopping = false,
    this.completed = const [],
    this.failed = const [],
    this.failureMode = QueueFailureMode.pause,
  });

  final List<QueuedTask> items;
  final bool active;
  final int done;
  final bool stopping;
  final List<QueueHistoryEntry> completed;
  final List<QueueHistoryEntry> failed;
  final QueueFailureMode failureMode;

  int get batch => done + 1;
  int get total => done + 1 + items.length;

  GenQueueState copyWith({
    List<QueuedTask>? items,
    bool? active,
    int? done,
    bool? stopping,
    List<QueueHistoryEntry>? completed,
    List<QueueHistoryEntry>? failed,
    QueueFailureMode? failureMode,
  }) => GenQueueState(
    items: items ?? this.items,
    active: active ?? this.active,
    done: done ?? this.done,
    stopping: stopping ?? this.stopping,
    completed: completed ?? this.completed,
    failed: failed ?? this.failed,
    failureMode: failureMode ?? this.failureMode,
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
    if (_poolCount >= cap) return false;
    // 与手动生成同语义:入队即按模块配置剥离,消费时不再看配置
    final snap = stripHiddenModules(
      ref.read(generateProvider),
      ref.read(genModulesProvider).value ?? const GenModuleSettings(),
    );
    return _enqueueSnapshot(
      snap,
      fixedTags: ref.read(fixedTagsProvider),
    );
  }

  bool _enqueueSnapshot(
    GenerateState snapshot, {
    bool front = false,
    FixedTagsState? fixedTags,
  }) {
    if (_poolCount >= cap) return false;
    final task = QueuedTask(
      id: _seq++,
      snapshot: snapshot,
      fixedTags: fixedTags ?? ref.read(fixedTagsProvider),
    );
    state = state.copyWith(
      items: front ? [task, ...state.items] : [...state.items, task],
    );
    return true;
  }

  int get _poolCount =>
      state.items.length + ref.read(generationProvider).jobs.length;

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

  void clearHistory() {
    state = state.copyWith(completed: const [], failed: const []);
  }

  void setFailureMode(QueueFailureMode mode) {
    if (state.failureMode != mode) {
      state = state.copyWith(failureMode: mode);
    }
  }

  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || newIndex < 0 ||
        oldIndex >= state.items.length || newIndex >= state.items.length) {
      return;
    }
    final items = [...state.items];
    items.insert(newIndex, items.removeAt(oldIndex));
    state = state.copyWith(items: items);
  }

  void removeHistory(int id) {
    state = state.copyWith(
      completed: [for (final e in state.completed) if (e.task.id != id) e],
      failed: [for (final e in state.failed) if (e.task.id != id) e],
    );
  }

  bool retryFailed(int id) {
    final entry = state.failed.where((e) => e.task.id == id).firstOrNull;
    if (entry == null) return false;
    // A failed task is left in items at the head so pressing Continue is also
    // a valid recovery path. An explicit Retry replaces that copy in place,
    // preventing duplicate tasks and keeping the failed item at the front.
    final hadQueuedCopy = state.items.any((task) => task.id == id);
    if (_poolCount - (hadQueuedCopy ? 1 : 0) >= cap) {
      return false;
    }
    final withoutFailedCopy = [
      for (final task in state.items)
        if (task.id != id) task,
    ];
    state = state.copyWith(items: withoutFailedCopy);
    final added = _enqueueSnapshot(
      entry.task.snapshot,
      front: true,
      fixedTags: entry.task.fixedTags,
    );
    if (!added) {
      // A concurrent generation can occupy the last pool slot between the
      // capacity check and enqueue. Restore the old task rather than losing a
      // failed job silently.
      state = state.copyWith(items: [entry.task, ...withoutFailedCopy]);
      return false;
    }
    removeHistory(id);
    return true;
  }

  /// 当前张跑完后暂停(不打断进行中的生成)。
  void stopAfterCurrent() {
    if (state.active) state = state.copyWith(stopping: true);
  }

  /// 有排队任务时开始消费;循环中让位,由对方收尾时再拉起。
  /// 手动生成中不再让位:并行之后手动那条只是池子里的一员,不挡队列。
  Future<void> maybeStart() async {
    if (state.active || state.items.isEmpty) return;
    if (ref.read(loopStatusProvider).active) return;
    await _drain();
  }

  Future<void> _drain() async {
    state = state.copyWith(active: true, done: 0, stopping: false);
    final gen = ref.read(generationProvider.notifier);
    var failed = false;

    // 同循环:一个 worker 一个并发槽。取队首与写回之间没有 await,
    // 单线程下两个 worker 不会抢到同一条。
    Future<void> worker() async {
      while (!state.stopping && !failed && state.items.isNotEmpty) {
        final task = state.items.first;
        state = state.copyWith(items: state.items.sublist(1));
        var outcome = await gen.generate(
          using: task.snapshot,
          fixedTags: task.fixedTags,
        );
        // **只有「确定未扣点」才重试。** 流中断 / 超时 / 内容审核这类失败,NAI
        // 可能已经受理并扣了点,盲目重试就是第二次扣费,而且没有任何用户动作。
        // 用户取消(stopping)同样不重试。见 S1B-01。
        // `rejected`(额度/资格被拒)虽然也确定没扣点,但重试必然同样被拒 ——
        // 它单独一个值就是为了在这里落到「不重试」这一边。
        if (outcome == GenOutcome.notCharged && !state.stopping) {
          outcome = await gen.generate(
            using: task.snapshot,
            fixedTags: task.fixedTags,
          );
        }
        if (outcome != GenOutcome.ok) {
          // A user stop is a pause, not a failed generation. Keep it queued
          // without polluting the failure history; real failures are recorded
          // and still remain at the head for an explicit retry/continue.
          final history = outcome == GenOutcome.cancelled
              ? state.failed
              : _appendHistory(
                  state.failed,
                  QueueHistoryEntry(
                    task: task,
                    outcome: outcome,
                    finishedAt: DateTime.now(),
                    message: _outcomeMessage(outcome),
                  ),
                );
          if (outcome != GenOutcome.cancelled &&
              state.failureMode == QueueFailureMode.skip) {
            state = state.copyWith(failed: history);
            continue;
          }
          failed = true;
          state = state.copyWith(
            items: [task, ...state.items],
            failed: history,
          );
          break;
        }
        state = state.copyWith(
          done: state.done + 1,
          completed: _appendHistory(
            state.completed,
            QueueHistoryEntry(
              task: task,
              outcome: outcome,
              finishedAt: DateTime.now(),
            ),
          ),
        );
      }
    }

    final workers = await gen.concurrency();
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);

    final done = state.done;
    final left = state.items.length;
    state = GenQueueState(
      items: state.items,
      completed: state.completed,
      failed: state.failed,
      failureMode: state.failureMode,
    );

    // 与循环同款收尾:岛上先显示完成态;前台不留通知,后台留一条汇总可点回应用
    final all = left == 0;
    await LiveProgress.instance.finish(
      title: all ? '队列完成' : '队列暂停',
      text: _appForeground ? '' : (all ? '共 $done 张 · 点按查看' : '剩 $left 项'),
      short: all ? '完成' : '暂停',
      keep: !_appForeground,
    );
  }

  static List<QueueHistoryEntry> _appendHistory(
    List<QueueHistoryEntry> source,
    QueueHistoryEntry entry,
  ) {
    const cap = 50;
    final next = [...source, entry];
    return next.length <= cap ? next : next.sublist(next.length - cap);
  }

  static String _outcomeMessage(GenOutcome outcome) => switch (outcome) {
    GenOutcome.cancelled => '已取消',
    GenOutcome.notCharged => '请求未受理',
    GenOutcome.maybeCharged => '生成失败，可能已扣点',
    GenOutcome.rejected => '额度或资格不足',
    GenOutcome.ok => '完成',
  };
}
