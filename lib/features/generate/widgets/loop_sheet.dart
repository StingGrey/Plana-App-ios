import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/anlas_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../cost.dart';
import '../generate_state.dart';
import '../generation_controller.dart';
import '../loop_controller.dart';
import '../models.dart';

/// 循环生成面板:选张数 → 看预估 → 开始;运行中切换为批次进度 + 停止。
/// 抓手由 BottomSheetTheme(showDragHandle: true)统一提供。
Future<void> showLoopSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _LoopSheet(),
  );
}

class _LoopSheet extends ConsumerWidget {
  const _LoopSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loop = ref.watch(loopStatusProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: loop.active ? _Running(loop: loop) : const _Setup(),
    );
  }
}

/// 配置态:张数档位(直接写回全局参数)+ 成本预估 + 开始。
class _Setup extends ConsumerWidget {
  const _Setup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final s = ref.watch(generateProvider);
    final p = s.params;
    final gen = ref.watch(generationProvider);
    final isOpus = ref.watch(anlasProvider).asData?.value?.isOpus ?? false;
    final cost = estimateCost(s, isOpus: isOpus);
    final n = p.loop.count;

    final costText = cost == 0
        ? '免费'
        : n > 0
        ? '$cost/张 · 共 ${cost * n} Anlas'
        : '$cost Anlas/张';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '循环生成',
          style: context.texts.titleMedium!.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '按当前创作参数连续出图;Seed 留空时每张随机。单张失败自动停止;可退到后台,通知栏跟进度。',
          style: context.texts.bodySmall!.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Text('张数', style: context.texts.bodyMedium)),
            SegmentedButton<LoopCount>(
              segments: [
                for (final l in LoopCount.values)
                  ButtonSegment(
                    value: l,
                    label: l == LoopCount.infinite
                        ? const Icon(Icons.all_inclusive, size: 15)
                        : Text(l.label),
                  ),
              ],
              selected: {p.loop},
              onSelectionChanged: (sel) =>
                  ref.read(generateProvider.notifier).setLoop(sel.first),
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity(horizontal: -3, vertical: -3),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: Text('预估消耗', style: context.texts.bodyMedium)),
            Text(
              costText,
              style: mono(
                context,
                size: 13,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: gen.busy
              ? null
              : () {
                  final notifier = ref.read(loopStatusProvider.notifier);
                  Navigator.pop(context);
                  notifier.start();
                },
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          child: Text(
            gen.busy ? '当前有生成进行中' : '开始循环 ${n > 0 ? '×$n' : '∞'}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// 运行态:第 n/N 张 + 合成进度(张数 + 当前张流式进度)+ 停止。
class _Running extends ConsumerWidget {
  const _Running({required this.loop});

  final LoopStatus loop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final gen = ref.watch(generationProvider);
    final progress = loop.total > 0
        ? (((loop.batch - 1) + (gen.progress ?? 0)) / loop.total).clamp(
            0.0,
            1.0,
          )
        : null; // ∞:不确定进度

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '循环生成中',
          style: context.texts.titleMedium!.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              loop.total > 0
                  ? '第 ${loop.batch} / ${loop.total} 张'
                  : '第 ${loop.batch} 张',
              style: context.texts.titleLarge!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            if (gen.total > 0 && gen.step > 0)
              Text(
                '${gen.step}/${gen.total}',
                style: mono(
                  context,
                  size: 13,
                ).copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: progress, minHeight: 6),
        ),
        const SizedBox(height: 18),
        FilledButton.tonal(
          onPressed: loop.stopping
              ? null
              : () => ref.read(loopStatusProvider.notifier).stop(),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          child: Text(
            loop.stopping ? '本张后停止…' : '停止(本张跑完后)',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
