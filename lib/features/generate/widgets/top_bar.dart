import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/anlas_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../generate_state.dart';
import '../models.dart' as m;

/// 顶栏:模型选择胶囊(左)+ Anlas 余额胶囊(右)
class GenerateTopBar extends ConsumerStatefulWidget {
  const GenerateTopBar({super.key});

  @override
  ConsumerState<GenerateTopBar> createState() => _GenerateTopBarState();
}

class _GenerateTopBarState extends ConsumerState<GenerateTopBar> {
  double _refreshTurns = 0;

  Future<void> _pickModel() async {
    final current = ref.read(generateProvider).params.model;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Text('模型',
                      style: context.texts.titleMedium!
                          .copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            for (final model in m.models)
              ListTile(
                onTap: () => Navigator.pop(context, model),
                title: Text(model, style: context.texts.bodyMedium),
                trailing: model == current
                    ? Icon(Icons.check, size: 18, color: context.scheme.primary)
                    : null,
                dense: true,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) ref.read(generateProvider.notifier).setModel(picked);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(generateProvider);
    final anlasValue = ref.watch(anlasProvider).asData?.value?.anlas;
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Row(
        children: [
          // 模型选择
          Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(19),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _pickModel,
              child: Padding(
                padding: const EdgeInsets.only(left: 14, right: 8),
                child: SizedBox(
                  height: 42,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: Motion.fast,
                        child: Text(
                          state.params.model,
                          key: ValueKey(state.params.model),
                          style: context.texts.bodyMedium!.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.expand_more, size: 20, color: scheme.outline),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          // Anlas 余额
          Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(19),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                setState(() => _refreshTurns += 1);
                ref.read(anlasProvider.notifier).refresh();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  height: 42,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.toll, size: 17, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        anlasValue != null ? _formatAnlas(anlasValue) : '—',
                        style: mono(context, size: 14, weight: FontWeight.w700)
                            .copyWith(color: scheme.primary),
                      ),
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: _refreshTurns,
                        duration: Motion.slow,
                        curve: Motion.standard,
                        child: Icon(Icons.refresh, size: 16, color: scheme.outline),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatAnlas(int v) {
  final s = v.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
