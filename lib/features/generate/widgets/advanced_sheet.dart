import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../generate_state.dart';
import '../models.dart';
import '../preset_manage_page.dart';
import '../prompt_presets.dart';
import 'common.dart';

/// 高级设置 Sheet:分区滚动,底部「恢复默认 / 确认」固定。
/// Sheet 内编辑草稿,确认才写回全局状态。
Future<void> showAdvancedSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) =>
        const FractionallySizedBox(heightFactor: .86, child: _AdvancedSheet()),
  );
}

class _AdvancedSheet extends ConsumerStatefulWidget {
  const _AdvancedSheet();

  @override
  ConsumerState<_AdvancedSheet> createState() => _AdvancedSheetState();
}

class _AdvancedSheetState extends ConsumerState<_AdvancedSheet> {
  late GenParams draft;
  late final TextEditingController seedCtrl;

  @override
  void initState() {
    super.initState();
    draft = ref.read(generateProvider).params;
    seedCtrl = TextEditingController(text: draft.seed);
  }

  @override
  void dispose() {
    seedCtrl.dispose();
    super.dispose();
  }

  void _set(GenParams next) => setState(() => draft = next);

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '高级设置',
                  style: context.texts.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 20),
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            children: [
              // 预设选择即时生效(全局偏好,不随「恢复默认/确认」走草稿)。
              _SectionLabel('提示词预设'),
              const SizedBox(height: 10),
              const _PresetRow(),
              const SizedBox(height: 4),
              Text(
                '生成时自动作为前缀拼进正/负提示词,不占用输入框。',
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.outline,
                ),
              ),
              const SizedBox(height: 18),
              Divider(
                color: scheme.outlineVariant.withValues(alpha: .5),
                height: 1,
              ),
              const SizedBox(height: 14),
              _SectionLabel('采样'),
              const SizedBox(height: 10),
              ParamSlider(
                label: '步数 Steps',
                value: draft.steps.toDouble(),
                min: 1,
                max: 50,
                divisions: 49,
                valueText: '${draft.steps}',
                trailing: AnimatedOpacity(
                  duration: Motion.fast,
                  opacity: draft.steps <= 28 ? 1 : 0,
                  child: const CountBadge('≤28 免费'),
                ),
                onChanged: (v) => _set(draft.copyWith(steps: v.round())),
              ),
              const SizedBox(height: 8),
              ParamSlider(
                label: '提示词引导 CFG',
                value: draft.cfg,
                min: 0,
                max: 25,
                divisions: 250, // step 0.1(对齐 web)
                valueText: draft.cfg.toStringAsFixed(1),
                trailing: FilterChip(
                  avatar: Icon(
                    Icons.shuffle,
                    size: 13,
                    color: draft.varietyPlus
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  label: const Text('Variety+', style: TextStyle(fontSize: 11)),
                  selected: draft.varietyPlus,
                  showCheckmark: false,
                  visualDensity: const VisualDensity(
                    horizontal: -3,
                    vertical: -3,
                  ),
                  onSelected: (v) => _set(draft.copyWith(varietyPlus: v)),
                ),
                onChanged: (v) => _set(draft.copyWith(cfg: v)),
              ),
              const SizedBox(height: 12),
              Text(
                '采样器 Sampler',
                style: context.texts.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 7,
                crossAxisSpacing: 7,
                childAspectRatio: 4.4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final s in samplers)
                    _SelectTile(
                      label: s,
                      selected: draft.sampler == s,
                      onTap: () => _set(draft.copyWith(sampler: s)),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '噪声调度 Noise Schedule',
                style: context.texts.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final n in noiseSchedules) ...[
                    Expanded(
                      child: _SelectTile(
                        label: n,
                        selected: draft.noiseSchedule == n,
                        height: 34,
                        onTap: () => _set(draft.copyWith(noiseSchedule: n)),
                      ),
                    ),
                    if (n != noiseSchedules.last) const SizedBox(width: 7),
                  ],
                ],
              ),
              const SizedBox(height: 18),
              Divider(
                color: scheme.outlineVariant.withValues(alpha: .5),
                height: 1,
              ),
              const SizedBox(height: 14),
              _SectionLabel('修正'),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: seedCtrl,
                      keyboardType: TextInputType.number,
                      style: mono(context, size: 13),
                      decoration: InputDecoration(
                        labelText: '种子 Seed',
                        hintText: '留空 = 随机',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        isDense: true,
                        suffixIcon: IconButton(
                          tooltip: '随机',
                          icon: const Icon(Icons.casino_outlined, size: 18),
                          onPressed: () {
                            seedCtrl.text =
                                (DateTime.now().millisecondsSinceEpoch %
                                        4294967296)
                                    .toString();
                          },
                        ),
                      ),
                      onChanged: (v) => _set(draft.copyWith(seed: v)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ParamSlider(
                label: 'CFG Rescale',
                value: draft.cfgRescale,
                divisions: 100, // step 0.01(对齐 web)
                onChanged: (v) => _set(draft.copyWith(cfgRescale: v)),
              ),
            ],
          ),
        ),
        // 底部固定按钮
        Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .5),
                width: .5,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    _set(
                      const GenParams().copyWith(
                        model: draft.model,
                        width: draft.width,
                        height: draft.height,
                      ),
                    );
                    seedCtrl.clear();
                  },
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text('恢复默认'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    ref
                        .read(generateProvider.notifier)
                        .applyParams(
                          draft.copyWith(seed: seedCtrl.text.trim()),
                        );
                    Navigator.pop(context);
                  },
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text(
                    '确认',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: context.texts.labelSmall!.copyWith(
        color: context.scheme.primary,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _SelectTile extends StatelessWidget {
  const _SelectTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.height = 36,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return AnimatedContainer(
      duration: Motion.fast,
      height: height,
      decoration: BoxDecoration(
        color: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: selected ? scheme.primary : Colors.transparent,
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 预设切换行:下拉单选即时生效(自定义多了 chip 行放不下,用户定稿下拉)
/// + 尾部「管理」进独立管理页。
class _PresetRow extends ConsumerWidget {
  const _PresetRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final s = ref.watch(promptPresetsProvider).value;
    if (s == null) return const SizedBox(height: 44);
    return Row(
      children: [
        Expanded(
          // DropdownButton 受控 value(FormField 版的 value 已弃用且替代品
          // 不响应外部变化):管理页改名/删除回落后,返回时显示自动跟随。
          child: InputDecorator(
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
            ),
            child: DropdownButton<String>(
              value: s.activeId,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(12),
              style: context.texts.bodyMedium!.copyWith(
                color: scheme.onSurface,
              ),
              items: [
                for (final p in s.presets)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (id) {
                if (id == null) return;
                HapticFeedback.selectionClick();
                ref.read(promptPresetsProvider.notifier).setActive(id);
              },
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: '管理预设',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.of(
            context,
          ).push(sharedAxisRoute(const PromptPresetManagePage())),
          icon: Icon(Icons.edit_note, size: 22, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
