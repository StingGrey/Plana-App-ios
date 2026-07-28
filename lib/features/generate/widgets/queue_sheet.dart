import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../gen_queue.dart';
import '../generation_controller.dart';

void showQueueSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    builder: (_) => const _QueueSheet(),
  );
}

class _QueueSheet extends ConsumerWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final q = ref.watch(genQueueProvider);
    final busy = ref.watch(generationProvider).busy;
    final paused = q.items.isNotEmpty && !q.active && !busy;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '生成队列',
                  style: context.texts.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  q.active
                      ? '第 ${q.batch}/${q.total} 项'
                      : '${q.items.length} 项',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (paused)
                  FilledButton.tonal(
                    onPressed: () {
                      ref.read(genQueueProvider.notifier).maybeStart();
                      Navigator.of(context).pop();
                    },
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('继续'),
                  ),
                TextButton(
                  onPressed: q.items.isEmpty
                      ? null
                      : ref.read(genQueueProvider.notifier).clear,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('清空'),
                ),
              ],
            ),
            if (q.items.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 18, 10, 22),
                child: Center(
                  child: Text(
                    '暂无排队任务 · 生成中点排队按钮即可加入',
                    style: context.texts.bodySmall!.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: q.items.length,
                  itemBuilder: (_, i) => _TaskRow(
                    index: i + 1,
                    task: q.items[i],
                    onRemove: () => ref
                        .read(genQueueProvider.notifier)
                        .remove(q.items[i].id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.index,
    required this.task,
    required this.onRemove,
  });

  final int index;
  final QueuedTask task;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final s = task.snapshot;
    final prompt = s.prompt.trim().replaceAll('\n', ' ');
    return Row(
      children: [
        SizedBox(
          width: 24,
          child: Text(
            '$index',
            style: mono(context, size: 12, color: scheme.outline),
          ),
        ),
        Expanded(
          child: Text(
            prompt.isEmpty ? '(无提示词)' : prompt,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodyMedium,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${s.params.width}×${s.params.height}',
          style: mono(context, size: 11, color: scheme.onSurfaceVariant),
        ),
        IconButton(
          onPressed: onRemove,
          icon: const Icon(Icons.close, size: 18),
          color: scheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
