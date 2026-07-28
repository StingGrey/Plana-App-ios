import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../lora/lora_manager_page.dart';
import '../generate_state.dart';
import '../lora_triggers.dart';
import '../models.dart';
import 'common.dart';
import 'section_card.dart';

/// LoRA 卡(anima 专属模块,样式对齐 web 桌面端 lora 模块):
/// 已挂列表(启用开关 · 缩略图 · 名称/类型徽标/触发词计数 · 权重),
/// 选中项展开权重滑杆与触发词行 —— 点触发词直接写进/移出正向提示词。
class LoraCard extends ConsumerStatefulWidget {
  const LoraCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  ConsumerState<LoraCard> createState() => _LoraCardState();
}

class _LoraCardState extends ConsumerState<LoraCard> {
  String? _selectedName;

  Future<void> _openManager() async {
    await Navigator.of(context).push(sharedAxisRoute(const LoraManagerPage()));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;

    final loras = state.loras;
    final expanded = state.openPanels.contains(Panel.lora) && loras.isNotEmpty;

    ActiveLora? selected;
    for (final l in loras) {
      if (l.name == _selectedName) {
        selected = l;
        break;
      }
    }
    selected ??= loras.isNotEmpty ? loras.first : null;

    return SectionCard(
      icon: Icons.auto_awesome_outlined,
      title: 'LoRA',
      reorderIndex: widget.reorderIndex,
      badge: loras.isEmpty ? null : CountBadge('${loras.length}'),
      actions: [
        RoundIconBtn(
          Icons.grid_view,
          tooltip: 'LoRA 管理器',
          color: loras.isEmpty ? scheme.primary : scheme.onSurfaceVariant,
          onTap: _openManager,
        ),
      ],
      expanded: expanded,
      onHeaderTap: loras.isEmpty ? _openManager : () => notifier.togglePanel(Panel.lora),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in loras) ...[
            _LoraRow(
              lora: l,
              selected: l.name == selected?.name,
              onTap: () => setState(() => _selectedName = l.name),
            ),
            const SizedBox(height: 6),
          ],
          if (selected != null) ...[
            const SizedBox(height: 8),
            _LoraDetail(
              lora: selected,
              onRemove: () {
                notifier.removeLora(selected!.name);
                final rest = ref.read(generateProvider).loras;
                setState(
                  () => _selectedName = rest.isEmpty ? null : rest.first.name,
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// 类型徽标(角色/画风/概念),配色对齐 web:pink/purple/cyan。
class LoraTypeBadge extends StatelessWidget {
  const LoraTypeBadge(this.type, {super.key});

  final String type;

  @override
  Widget build(BuildContext context) {
    final color = switch (type) {
      'character' => const Color(0xFFEC4899),
      'style' => const Color(0xFFA855F7),
      _ => const Color(0xFF06B6D4),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        loraTypeLabel(type),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// LoRA 缩略图(远端预览直链;取不到时用闪光图标占位)。
class LoraThumb extends StatelessWidget {
  const LoraThumb(this.url, {super.key, this.size = 40});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fallback = Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHigh,
      child: Icon(
        Icons.auto_awesome,
        size: size * .5,
        color: scheme.onSurfaceVariant,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: url.isEmpty
          ? fallback
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

class _LoraRow extends ConsumerWidget {
  const _LoraRow({
    required this.lora,
    required this.selected,
    required this.onTap,
  });

  final ActiveLora lora;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final prompt = ref.watch(generateProvider.select((s) => s.prompt));
    final added = lora.triggerWords
        .where((t) => promptHasTrigger(prompt, t))
        .length;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: .08)
          : scheme.surfaceContainerHigh.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Opacity(
                opacity: lora.enabled ? 1 : .4,
                child: LoraThumb(lora.previewUrl),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Opacity(
                  opacity: lora.enabled ? 1 : .55,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lora.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodyMedium!.copyWith(
                          fontWeight: FontWeight.w600,
                          decoration: lora.enabled
                              ? null
                              : TextDecoration.lineThrough,
                          color: lora.enabled
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          LoraTypeBadge(lora.type),
                          if (lora.triggerWords.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.key,
                              size: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '$added/${lora.triggerWords.length}',
                              style: context.texts.labelSmall!.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'w${lora.weight.toStringAsFixed(2)}',
                style: mono(
                  context,
                  size: 12,
                  color: lora.enabled ? scheme.primary : scheme.outline,
                ),
              ),
              if (!lora.enabled) ...[
                const SizedBox(width: 6),
                Icon(Icons.visibility_off, size: 15, color: scheme.outline),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中项详情:启用/移除 + 权重滑杆 + 触发词行(点击写进/移出正向词)。
class _LoraDetail extends ConsumerWidget {
  const _LoraDetail({required this.lora, required this.onRemove});

  final ActiveLora lora;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    final prompt = ref.watch(generateProvider.select((s) => s.prompt));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            RefEnableToggle(
              enabled: lora.enabled,
              onTap: () =>
                  notifier.updateLora(lora.name, enabled: !lora.enabled),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                lora.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodyLarge!.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: scheme.error,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '移除',
                        style: context.texts.bodyMedium!.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LiveParamSlider(
          label: 'Weight 权重',
          help: Help.loraWeight,
          value: lora.weight,
          max: kLoraWeightMax,
          divisions: 40, // step 0.05(对齐 web LoraNumberInput)
          onCommit: (v) => notifier.updateLora(lora.name, weight: v),
        ),
        if (lora.triggerWords.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '触发词 · 点击写入/移出正向提示词',
            style: context.texts.labelSmall!.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 6),
          for (final tw in lora.triggerWords) ...[
            _TriggerRow(
              trigger: tw,
              added: promptHasTrigger(prompt, tw),
              onTap: () {
                final cur = ref.read(generateProvider).prompt;
                notifier.setPrompts(
                  positive: promptHasTrigger(cur, tw)
                      ? removeTriggerFromPrompt(cur, tw)
                      : appendTriggerToPrompt(cur, tw),
                );
              },
            ),
            const SizedBox(height: 5),
          ],
        ],
      ],
    );
  }
}

class _TriggerRow extends StatelessWidget {
  const _TriggerRow({
    required this.trigger,
    required this.added,
    required this.onTap,
  });

  final String trigger;
  final bool added;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: added
          ? scheme.primary.withValues(alpha: .13)
          : scheme.surfaceContainerHigh.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(9),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: added
                  ? scheme.primary.withValues(alpha: .5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                added ? Icons.check : Icons.add,
                size: 14,
                color: added ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  trigger,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(
                    color: added ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
