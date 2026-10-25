import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show confirmDialog, hintSnack;
import '../tag_library.dart';
import '../tag_models.dart';

/// 类别管理:页签排序(拖动)、⏻ 隐藏、自定义类别的新建 / 改名 / 删除。
/// 版式同标签池管理那张。
Future<void> showCategoryManagerSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _ManagerSheet(),
    );

class _ManagerSheet extends ConsumerWidget {
  const _ManagerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final lib = ref.watch(tagLibraryProvider).value ?? const TagLibraryState();
    final notifier = ref.read(tagLibraryProvider.notifier);
    final keys = lib.tabKeys;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.dashboard_customize_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '类别',
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              // 顺序即顶栏页签的顺序:按住抓手即拖,整行长按也可拖
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                proxyDecorator: (child, index, animation) => Material(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 3,
                  child: child,
                ),
                onReorderItem: notifier.moveTab,
                itemCount: keys.length,
                itemBuilder: (context, i) =>
                    ReorderableDelayedDragStartListener(
                      key: ValueKey(keys[i]),
                      index: i,
                      child: _row(context, ref, lib, keys[i], i),
                    ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: OutlinedButton.icon(
                onPressed: () => _create(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建类别'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref,
    TagLibraryState lib,
    String key,
    int index,
  ) {
    final scheme = context.scheme;
    final notifier = ref.read(tagLibraryProvider.notifier);
    final codex = key == kCodexTabKey;
    final cat = codex ? null : tagCategoryByWebId(key);
    final def = cat == null ? null : tagCategoryDef(cat);
    final custom = cat?.isCustom ?? false;
    final hidden = lib.hidden.contains(key);
    final canHide = custom || kHideableTabKeys.contains(key);
    final fg = hidden ? scheme.outline : scheme.onSurface;
    return ListTile(
      dense: true,
      onTap: custom ? () => _edit(context, ref, def!) : null,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: SizedBox(
              width: 30,
              height: 40,
              child: Icon(Icons.reorder, size: 20, color: scheme.outline),
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            codex ? Icons.menu_book_outlined : def!.icon,
            size: 20,
            color: hidden ? scheme.outline : scheme.onSurfaceVariant,
          ),
        ],
      ),
      title: Text(
        codex ? '法典' : def!.label,
        style: context.texts.bodyLarge!.copyWith(color: fg),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (cat != null)
            Text(
              '${lib.of(cat).length}',
              style: mono(context, size: 12, color: scheme.outline),
            ),
          if (canHide)
            IconButton(
              tooltip: hidden ? '显示' : '隐藏',
              icon: Icon(
                Icons.power_settings_new,
                size: 20,
                color: hidden ? scheme.outline : scheme.primary,
              ),
              onPressed: () => notifier.setTabHidden(key, !hidden),
            )
          else
            const SizedBox(width: 48),
          if (custom)
            IconButton(
              tooltip: '删除',
              icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
              onPressed: () => _remove(context, ref, lib, def!),
            ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final v = await showCategoryEditDialog(context, ref);
    if (v == null) return;
    await ref
        .read(tagLibraryProvider.notifier)
        .addCategory(label: v.label, iconName: v.iconName, layout: v.layout);
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    TagCategoryDef def,
  ) async {
    final v = await showCategoryEditDialog(context, ref, edit: def);
    if (v == null) return;
    await ref
        .read(tagLibraryProvider.notifier)
        .updateCategory(
          TagCategoryDef.custom(
            id: def.webId,
            label: v.label,
            iconName: v.iconName,
            layout: v.layout,
          ),
        );
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    TagLibraryState lib,
    TagCategoryDef def,
  ) async {
    final n = lib.of(def.key).length;
    final ok = await confirmDialog(
      context,
      title: '删除「${def.label}」?',
      message: n == 0 ? '这个类别还没有条目。' : '类别里的 $n 个条目会一起删除,不可恢复。',
      confirmLabel: '删除',
    );
    if (ok) await ref.read(tagLibraryProvider.notifier).removeCategory(def.key);
  }
}

typedef CategoryForm = ({String label, String iconName, TagCardLayout layout});

/// 新建 / 编辑类别:名称、图标、预览图形状。取消返回 null。
Future<CategoryForm?> showCategoryEditDialog(
  BuildContext context,
  WidgetRef ref, {
  TagCategoryDef? edit,
}) => showDialog<CategoryForm>(
  context: context,
  builder: (_) => _EditDialog(edit: edit),
);

class _EditDialog extends ConsumerStatefulWidget {
  const _EditDialog({this.edit});

  final TagCategoryDef? edit;

  @override
  ConsumerState<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends ConsumerState<_EditDialog> {
  late final _name = TextEditingController(text: widget.edit?.label ?? '');
  late String _icon = widget.edit?.iconName ?? kTagCategoryIcons.keys.first;
  late TagCardLayout _layout = widget.edit?.layout ?? TagCardLayout.square;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _name.text.trim();
    if (label.isEmpty) return;
    final lib = ref.read(tagLibraryProvider).value;
    final taken = {
      for (final d in kTagCategoryDefs) d.label,
      for (final d in lib?.customDefs ?? const <TagCategoryDef>[])
        if (d.webId != widget.edit?.webId) d.label,
      '法典',
    };
    if (taken.contains(label)) {
      hintSnack(context, '已有同名类别', icon: Icons.error_outline);
      return;
    }
    Navigator.pop(context, (label: label, iconName: _icon, layout: _layout));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final muted = context.texts.labelMedium!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: Text(widget.edit == null ? '新建类别' : '编辑类别'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.edit == null,
              maxLength: 8,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '名称',
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Text('图标', style: muted),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in kTagCategoryIcons.entries)
                  Material(
                    color: e.key == _icon
                        ? scheme.primary
                        : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => setState(() => _icon = e.key),
                      child: SizedBox(
                        width: 38,
                        height: 38,
                        child: Icon(
                          e.value,
                          size: 20,
                          color: e.key == _icon
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('预览图', style: muted),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<TagCardLayout>(
                showSelectedIcon: false,
                segments: [
                  for (final l in TagCardLayout.values)
                    ButtonSegment(value: l, label: Text(l.label)),
                ],
                selected: {_layout},
                onSelectionChanged: (v) => setState(() => _layout = v.first),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty ? null : _submit,
          child: Text(widget.edit == null ? '创建' : '保存'),
        ),
      ],
    );
  }
}
