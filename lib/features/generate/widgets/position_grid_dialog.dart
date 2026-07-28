import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../generate_state.dart';

/// 角色站位 5×5 网格弹窗(列 A-E × 行 1-5)。
/// 其他角色占用的格子灰显其序号;AUTO = 交给 AI 摆位。
Future<void> showPositionGridDialog(BuildContext context, String charId) {
  return showDialog(
    context: context,
    builder: (context) => _PositionDialog(charId: charId),
  );
}

class _PositionDialog extends ConsumerStatefulWidget {
  const _PositionDialog({required this.charId});

  final String charId;

  @override
  ConsumerState<_PositionDialog> createState() => _PositionDialogState();
}

class _PositionDialogState extends ConsumerState<_PositionDialog> {
  String? pos;

  @override
  void initState() {
    super.initState();
    pos = ref
        .read(generateProvider)
        .characters
        .firstWhere((c) => c.id == widget.charId)
        .position;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final chars = ref.read(generateProvider).characters;
    final me = chars.firstWhere((c) => c.id == widget.charId);
    final myIndex = chars.indexOf(me) + 1;
    // 每格其他角色的编号列表(可叠放)
    final occ = <String, List<int>>{};
    for (final c in chars) {
      if (c.id != me.id && c.position != null) {
        (occ[c.position!] ??= []).add(chars.indexOf(c) + 1);
      }
    }

    return Dialog(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.grid_on, size: 19, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '角色位置 · ${me.name}',
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                  color: scheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 列标
            Row(
              children: [
                const SizedBox(width: 26),
                for (final col in 'ABCDE'.split(''))
                  Expanded(
                    child: Center(
                      child: Text(
                        col,
                        style: context.texts.labelSmall!.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            for (var row = 1; row <= 5; row++) ...[
              Row(
                children: [
                  SizedBox(
                    width: 26,
                    child: Center(
                      child: Text(
                        '$row',
                        style: context.texts.labelSmall!.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  for (final col in 'ABCDE'.split('')) ...[
                    Expanded(child: _cell(context, '$col$row', myIndex, occ)),
                  ],
                ],
              ),
              if (row < 5) const SizedBox(height: 6),
            ],
            const SizedBox(height: 12),
            // 图例
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final c in chars)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: c.id == me.id
                              ? scheme.primary
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Center(
                          child: Text(
                            '${chars.indexOf(c) + 1}',
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                              color: c.id == me.id
                                  ? scheme.onPrimary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${c.name} ${c.position ?? "AUTO"}',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      ref
                          .read(generateProvider.notifier)
                          .updateCharacter(widget.charId, position: null);
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('AUTO'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: pos == null
                        ? null
                        : () {
                            ref
                                .read(generateProvider.notifier)
                                .updateCharacter(widget.charId, position: pos);
                            Navigator.pop(context);
                          },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                    child: Text(
                      '确认${pos == null ? '' : ' $pos'}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    String code,
    int myIndex,
    Map<String, List<int>> occ,
  ) {
    final scheme = context.scheme;
    final mine = pos == code;
    final others = occ[code] ?? const <int>[];
    // 本格全部占用者(含我,若我选了这格)
    final all = [if (mine) myIndex, ...others]..sort();
    final stacked = all.length >= 2;

    late final Color bg;
    Border? border;
    Widget? content;

    if (stacked) {
      // 叠放:醒目的第三色 + 层叠图标 + 编号串;若含我则加主色描边
      bg = scheme.tertiaryContainer;
      if (mine) border = Border.all(color: scheme.primary, width: 2);
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers, size: 13, color: scheme.onTertiaryContainer),
          const SizedBox(height: 1),
          Text(
            all.join('·'),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: scheme.onTertiaryContainer,
            ),
          ),
        ],
      );
    } else if (mine) {
      bg = scheme.primary;
      content = Text(
        '$myIndex',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimary,
        ),
      );
    } else if (others.length == 1) {
      bg = scheme.surfaceContainerHighest;
      border = Border.all(color: scheme.outline.withValues(alpha: .4));
      content = Text(
        '${others.first}',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
        ),
      );
    } else {
      bg = scheme.surfaceContainerHigh;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: AspectRatio(
        aspectRatio: 1,
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.standard,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(9),
            border: border,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() => pos = mine ? null : code),
              child: Center(child: content),
            ),
          ),
        ),
      ),
    );
  }
}
