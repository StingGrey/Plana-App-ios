import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import 'prompt_presets.dart';
import 'widgets/common.dart';
import '../../core/util/haptics.dart';

/// 提示词预设管理页:激活切换 + 自定义增删改;默认预设只读可查看。
/// 入口:高级设置「管理预设」/ 我的页卡片。
class PromptPresetManagePage extends ConsumerWidget {
  const PromptPresetManagePage({super.key});

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    PromptPreset? preset,
  }) async {
    final r =
        await showModalBottomSheet<
          ({String name, String positive, String negative})
        >(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => _PresetEditSheet(preset: preset),
        );
    if (r == null) return; // 取消 / 只读查看
    final n = ref.read(promptPresetsProvider.notifier);
    if (preset == null) {
      await n.add(name: r.name, positive: r.positive, negative: r.negative);
    } else {
      await n.updatePreset(
        preset.id,
        name: r.name,
        positive: r.positive,
        negative: r.negative,
      );
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    PromptPreset p,
  ) async {
    final ok = await confirmDialog(
      context,
      title: '删除预设',
      message: '「${p.name}」将被删除;若正在激活,回落到「无」。',
      confirmLabel: '删除',
    );
    if (!ok) return;
    await ref.read(promptPresetsProvider.notifier).remove(p.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final s = ref.watch(promptPresetsProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('提示词预设'),
        actions: [
          IconButton(
            tooltip: '新建预设',
            onPressed: () => _edit(context, ref),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 6, 12),
                  child: Text(
                    '激活的预设在生成时自动作为前缀拼进正/负提示词,不占用输入框。'
                    '默认预设不可修改;右上角可新建自定义预设。',
                    style: context.texts.bodySmall!.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
                for (final p in s.presets) ...[
                  _PresetTile(
                    preset: p,
                    active: p.id == s.activeId,
                    onTap: () {
                      Haptics.selection();
                      ref.read(promptPresetsProvider.notifier).setActive(p.id);
                    },
                    onEdit: () => _edit(context, ref, preset: p),
                    onDelete: p.isDefault
                        ? null
                        : () => _delete(context, ref, p),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.active,
    required this.onTap,
    required this.onEdit,
    this.onDelete,
  });

  final PromptPreset preset;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: active
            ? BorderSide(color: scheme.primary, width: 1.4)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              Icon(
                active ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: active ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            preset.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.bodyMedium!.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (preset.isDefault) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            // 带系列的内置档直接报系列 —— 4.5 的 Light 和 V5 的
                            // Light 同名,只挂个「默认」两条会长得一模一样。
                            child: Text(
                              switch (preset.scope) {
                                'v5' => 'V5',
                                'legacy' => '4.5 及更早',
                                _ => '默认',
                              },
                              style: context.texts.labelSmall!.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (preset.positive.isEmpty && preset.negative.isEmpty)
                      Text(
                        '无前缀',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.outline,
                        ),
                      )
                    else ...[
                      if (preset.positive.isNotEmpty)
                        Text(
                          '+ ${preset.positive}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.labelSmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      if (preset.negative.isNotEmpty)
                        Text(
                          '- ${preset.negative}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.labelSmall!.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: preset.isDefault ? '查看' : '编辑',
                visualDensity: VisualDensity.compact,
                onPressed: onEdit,
                icon: Icon(
                  preset.isDefault
                      ? Icons.visibility_outlined
                      : Icons.edit_outlined,
                  size: 19,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (onDelete != null)
                IconButton(
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 19,
                    color: scheme.error.withValues(alpha: .85),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新建 / 编辑 / 只读查看(默认预设)三合一 sheet。
/// controller 归 State 管(pop future 在退场动画时 resolve,外部 dispose 会崩)。
class _PresetEditSheet extends StatefulWidget {
  const _PresetEditSheet({this.preset});

  final PromptPreset? preset;

  @override
  State<_PresetEditSheet> createState() => _PresetEditSheetState();
}

class _PresetEditSheetState extends State<_PresetEditSheet> {
  late final TextEditingController nameCtl = TextEditingController(
    text: widget.preset?.name ?? '',
  );
  late final TextEditingController posCtl = TextEditingController(
    text: widget.preset?.positive ?? '',
  );
  late final TextEditingController negCtl = TextEditingController(
    text: widget.preset?.negative ?? '',
  );

  bool get _readOnly => widget.preset?.isDefault ?? false;

  @override
  void dispose() {
    nameCtl.dispose();
    posCtl.dispose();
    negCtl.dispose();
    super.dispose();
  }

  Widget _field(
    String label,
    TextEditingController ctl, {
    bool multiline = false,
  }) {
    final scheme = context.scheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.texts.labelMedium!.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: ctl,
          readOnly: _readOnly,
          minLines: multiline ? 2 : 1,
          maxLines: multiline ? 6 : 1,
          style: multiline ? mono(context, size: 13) : null,
          decoration: InputDecoration(
            isDense: true,
            hintText: multiline ? '空…' : '预设名称',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final title = _readOnly
        ? '查看预设'
        : widget.preset == null
        ? '新建预设'
        : '编辑预设';
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: context.texts.titleMedium!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (_readOnly) ...[
            const SizedBox(height: 4),
            Text(
              '默认预设不可修改,可新建自定义预设替代。',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ],
          const SizedBox(height: 14),
          _field('名称', nameCtl),
          const SizedBox(height: 12),
          _field('正向前缀', posCtl, multiline: true),
          const SizedBox(height: 12),
          _field('负向前缀', negCtl, multiline: true),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_readOnly ? '关闭' : '取消'),
              ),
              if (!_readOnly) ...[
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final name = nameCtl.text.trim();
                    Navigator.pop(context, (
                      name: name.isEmpty ? '未命名' : name,
                      positive: posCtl.text.trim(),
                      negative: negCtl.text.trim(),
                    ));
                  },
                  child: const Text('保存'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
