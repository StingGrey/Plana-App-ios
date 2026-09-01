import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../generate/gen_jobs.dart';
import '../generate/gen_queue.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart' show GenerateState;
import '../generate/generation_controller.dart';
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;

/// Queue management screen for submitted snapshots.
///
/// The existing generation controller remains the single execution authority;
/// this page only edits pending snapshots and observes the live task pool.
class QueueManagementPage extends ConsumerStatefulWidget {
  const QueueManagementPage({super.key});

  @override
  ConsumerState<QueueManagementPage> createState() =>
      _QueueManagementPageState();
}

class _QueueManagementPageState extends ConsumerState<QueueManagementPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(genQueueProvider);
    final pool = ref.watch(generationProvider);
    final scheme = context.scheme;
    final failedCount = queue.failed.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('生成队列'),
        actions: [
          if (queue.active)
            IconButton(
              tooltip: queue.stopping ? '等待当前任务完成' : '暂停队列',
              icon: Icon(queue.stopping ? Icons.hourglass_top : Icons.pause),
              onPressed: queue.stopping
                  ? null
                  : () => ref.read(genQueueProvider.notifier).stopAfterCurrent(),
            )
          else if (queue.items.isNotEmpty)
            IconButton(
              tooltip: '继续队列',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => ref.read(genQueueProvider.notifier).maybeStart(),
            ),
          if (queue.items.isNotEmpty || queue.completed.isNotEmpty || failedCount > 0)
            IconButton(
              tooltip: '清空队列记录',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _clearQueue(queue),
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: '待处理 ${queue.items.length}'),
            Tab(text: '运行中 ${pool.jobs.length}'),
            Tab(text: '历史 ${queue.completed.length + failedCount}'),
          ],
        ),
      ),
      body: Column(
        children: [
          _summary(queue, pool, scheme),
          _failureModeBar(queue),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _pending(queue),
                _running(pool),
                _history(queue),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _failureModeBar(GenQueueState queue) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: context.scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('失败处理', style: context.texts.labelMedium),
          const SizedBox(width: 8),
          DropdownButton<QueueFailureMode>(
            value: queue.failureMode,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final mode in QueueFailureMode.values)
                DropdownMenuItem(value: mode, child: Text(mode.label)),
            ],
            onChanged: queue.active
                ? null
                : (mode) {
                    if (mode != null) {
                      ref.read(genQueueProvider.notifier).setFailureMode(mode);
                    }
                  },
          ),
          if (queue.failureMode == QueueFailureMode.pause) ...[
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '更安全：可能扣点的失败不会自动重试',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: context.texts.labelSmall!.copyWith(color: context.scheme.outline),
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }

  Widget _summary(GenQueueState queue, GenPool pool, ColorScheme scheme) {
    final total = queue.items.length + pool.jobs.length;
    final status = queue.active
        ? (queue.stopping ? '当前任务结束后暂停' : '队列执行中')
        : (queue.items.isEmpty ? '队列空闲' : '等待开始');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 11),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(
            queue.active ? Icons.sync : Icons.queue_outlined,
            size: 19,
            color: queue.active ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status,
              style: context.texts.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            '$total 项 · 已完成 ${queue.completed.length} · 失败 ${queue.failed.length}',
            style: context.texts.labelSmall!.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _pending(GenQueueState queue) {
    if (queue.items.isEmpty) {
      return _empty(Icons.inbox_outlined, '没有待处理任务', '在创作页点队列按钮添加当前参数');
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
      itemCount: queue.items.length,
      onReorderItem: (oldIndex, newIndex) {
        ref.read(genQueueProvider.notifier).reorder(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final task = queue.items[index];
        return _QueuedTaskTile(
          key: ValueKey(task.id),
          index: index,
          task: task,
          onRemove: () => ref.read(genQueueProvider.notifier).remove(task.id),
          onLoad: () => _loadSnapshot(task.snapshot),
        );
      },
    );
  }

  Widget _running(GenPool pool) {
    if (pool.jobs.isEmpty) {
      return _empty(Icons.hourglass_empty, '当前没有运行中的任务', '队列开始后会在这里显示实时进度');
    }
    final jobs = pool.newestFirst;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
      itemCount: jobs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, index) => _RunningTaskTile(
        job: jobs[index],
        selected: jobs[index].id == pool.selectedId,
        onSelect: () => ref.read(generationProvider.notifier).select(jobs[index].id),
        onCancel: () => ref.read(generationProvider.notifier).cancelJob(jobs[index].id),
      ),
    );
  }

  Widget _history(GenQueueState queue) {
    final entries = <QueueHistoryEntry>[
      ...queue.completed,
      ...queue.failed,
    ]..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
    if (entries.isEmpty) {
      return _empty(Icons.history_outlined, '还没有队列历史', '完成或失败的任务会保留在这里');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, index) {
        final entry = entries[index];
        return _HistoryTile(
          entry: entry,
          onRetry: entry.succeeded
              ? null
              : () {
                  final ok = ref.read(genQueueProvider.notifier).retryFailed(entry.task.id);
                  if (ok) {
                    hintSnack(
                      context,
                      '已重新加入队列',
                      icon: Icons.playlist_add_check,
                    );
                    unawaited(
                      ref.read(genQueueProvider.notifier).maybeStart(),
                    );
                  }
                },
          onDelete: () => ref.read(genQueueProvider.notifier).removeHistory(entry.task.id),
        );
      },
    );
  }

  Widget _empty(IconData icon, String title, String subtitle) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 50, color: context.scheme.outlineVariant),
          const SizedBox(height: 12),
          Text(title, style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text(subtitle, textAlign: TextAlign.center, style: context.texts.bodySmall!.copyWith(color: context.scheme.outline)),
        ],
      ),
    ),
  );

  void _loadSnapshot(GenerateState snapshot) {
    ref.read(generateProvider.notifier).loadSnapshot(snapshot);
    hintSnack(context, '已载入创作页，可继续修改参数', icon: Icons.edit_outlined);
  }

  Future<void> _clearQueue(GenQueueState queue) async {
    final ok = await confirmDialog(
      context,
      title: '清空队列记录',
      message: '待处理任务和已完成/失败记录都会移除，正在运行的任务不会被强制取消。',
      confirmLabel: '清空',
    );
    if (!ok || !mounted) return;
    final notifier = ref.read(genQueueProvider.notifier);
    notifier.clear();
    notifier.clearHistory();
  }
}

class _QueuedTaskTile extends StatelessWidget {
  const _QueuedTaskTile({
    super.key,
    required this.index,
    required this.task,
    required this.onRemove,
    required this.onLoad,
  });

  final int index;
  final QueuedTask task;
  final VoidCallback onRemove;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final s = task.snapshot;
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(8, 4, 5, 4),
          leading: ReorderableDragStartListener(
            index: index,
            child: const SizedBox(
              width: 42,
              height: 48,
              child: Icon(Icons.drag_handle),
            ),
          ),
          title: Text(
            s.prompt.isEmpty ? '空提示词' : s.prompt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall!.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${s.params.model} · ${s.params.width}×${s.params.height} · ${s.params.activeSteps} 步',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '任务操作',
            onSelected: (value) {
              if (value == 'load') onLoad();
              if (value == 'remove') onRemove();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'load', child: Text('载入创作页')),
              PopupMenuItem(value: 'remove', child: Text('移除任务')),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunningTaskTile extends StatelessWidget {
  const _RunningTaskTile({
    required this.job,
    required this.selected,
    required this.onSelect,
    required this.onCancel,
  });

  final GenJob job;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final progress = job.progress;
    final label = job.sampling
        ? '${job.step}/${job.total}'
        : (job.note ?? _stageLabel(job.stage));
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: .45)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 11, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    job.kind == GenJobKind.inpaint ? Icons.brush : Icons.auto_awesome,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${job.width} × ${job.height}', style: context.texts.bodyMedium!.copyWith(fontWeight: FontWeight.w700))),
                  Text(label, style: context.texts.labelMedium!.copyWith(color: scheme.primary)),
                  IconButton(
                    tooltip: '取消任务',
                    icon: const Icon(Icons.close, size: 19),
                    onPressed: onCancel,
                  ),
                ],
              ),
              const SizedBox(height: 5),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 6),
              Text(
                job.preview == null ? '预览尚未生成' : '已有实时预览',
                style: context.texts.labelSmall!.copyWith(color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.entry,
    required this.onRetry,
    required this.onDelete,
  });

  final QueueHistoryEntry entry;
  final VoidCallback? onRetry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final s = entry.task.snapshot;
    final ok = entry.succeeded;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: Icon(
          ok ? Icons.check_circle_outline : Icons.error_outline,
          color: ok ? FixedSemantic.ok : scheme.error,
        ),
        title: Text(
          s.prompt.isEmpty ? '空提示词' : s.prompt,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          ok ? '已完成 · ${s.params.model}' : (entry.message ?? '生成失败'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          tooltip: '历史操作',
          onSelected: (value) {
            if (value == 'retry') onRetry?.call();
            if (value == 'delete') onDelete();
          },
          itemBuilder: (_) => [
            if (onRetry != null)
              const PopupMenuItem(value: 'retry', child: Text('重试')),
            const PopupMenuItem(value: 'delete', child: Text('删除记录')),
          ],
        ),
      ),
    );
  }
}

String _stageLabel(GenJobStage stage) => switch (stage) {
  GenJobStage.waiting => '等待资源',
  GenJobStage.preparing => '准备中',
  GenJobStage.queued => '服务端排队',
  GenJobStage.starting => '启动模型',
  GenJobStage.running => '生成中',
};
