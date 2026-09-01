import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import 'fixed_tags.dart';

/// Reusable positive/negative prompt fragments.
class FixedTagsPage extends ConsumerStatefulWidget {
  const FixedTagsPage({super.key});

  @override
  ConsumerState<FixedTagsPage> createState() => _FixedTagsPageState();
}

class _FixedTagsPageState extends ConsumerState<FixedTagsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final entry = await showDialog<FixedTagEntry>(
      context: context,
      builder: (_) => const _FixedTagEditor(),
    );
    if (entry != null) ref.read(fixedTagsProvider.notifier).upsert(entry);
  }

  Future<void> _edit(FixedTagEntry entry) async {
    final next = await showDialog<FixedTagEntry>(
      context: context,
      builder: (_) => _FixedTagEditor(initial: entry),
    );
    if (next != null) ref.read(fixedTagsProvider.notifier).upsert(next);
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空固定词'),
        content: const Text('所有固定词都会删除，生成页的提示词正文不会改变。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
        ],
      ),
    );
    if (yes == true) ref.read(fixedTagsProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fixedTagsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('固定词库'),
        actions: [
          if (state.entries.isNotEmpty)
            IconButton(tooltip: '清空', icon: const Icon(Icons.delete_sweep_outlined), onPressed: _clear),
          IconButton(tooltip: '新建固定词', icon: const Icon(Icons.add), onPressed: _add),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: '正向 ${state.positive.length}'),
            Tab(text: '负向 ${state.negative.length}'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _list(FixedTagSide.positive, state.positive),
          _list(FixedTagSide.negative, state.negative),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新建固定词',
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _list(FixedTagSide side, List<FixedTagEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.push_pin_outlined, size: 48, color: context.scheme.outlineVariant),
            const SizedBox(height: 10),
            Text('还没有固定词', style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text('固定词会在每次生成时自动拼入提示词', style: context.texts.bodySmall!.copyWith(color: context.scheme.outline)),
            const SizedBox(height: 14),
            FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('新建')),
          ],
        ),
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
      itemCount: entries.length,
      onReorderItem: (oldIndex, newIndex) {
        ref.read(fixedTagsProvider.notifier).reorder(side, oldIndex, newIndex);
      },
      itemBuilder: (_, index) {
        final entry = entries[index];
        return _FixedTagTile(
          key: ValueKey(entry.id),
          entry: entry,
          index: index,
          onToggle: () => ref.read(fixedTagsProvider.notifier).toggle(entry.id),
          onEdit: () => _edit(entry),
          onDelete: () => ref.read(fixedTagsProvider.notifier).remove(entry.id),
        );
      },
    );
  }
}

class _FixedTagTile extends StatelessWidget {
  const _FixedTagTile({
    super.key,
    required this.entry,
    required this.index,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final FixedTagEntry entry;
  final int index;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final position = entry.position == FixedTagPosition.prefix ? '前置' : '后置';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: entry.enabled ? scheme.surfaceContainerLow : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(7, 4, 5, 4),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle)),
              Switch(value: entry.enabled, onChanged: (_) => onToggle),
            ],
          ),
          title: Text(
            entry.name.isEmpty ? entry.content : entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodyMedium!.copyWith(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${entry.weightedContent} · $position',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall!.copyWith(color: scheme.onSurfaceVariant),
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '固定词操作',
            onSelected: (value) {
              if (value == 'edit') onEdit();
              if (value == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ),
      ),
    );
  }
}

class _FixedTagEditor extends StatefulWidget {
  const _FixedTagEditor({this.initial});

  final FixedTagEntry? initial;

  @override
  State<_FixedTagEditor> createState() => _FixedTagEditorState();
}

class _FixedTagEditorState extends State<_FixedTagEditor> {
  late final TextEditingController _name;
  late final TextEditingController _content;
  late FixedTagSide _side;
  late FixedTagPosition _position;
  late double _weight;

  @override
  void initState() {
    super.initState();
    final entry = widget.initial;
    _name = TextEditingController(text: entry?.name ?? '');
    _content = TextEditingController(text: entry?.content ?? '');
    _side = entry?.side ?? FixedTagSide.positive;
    _position = entry?.position ?? FixedTagPosition.prefix;
    _weight = entry?.weight ?? 1;
  }

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  void _submit() {
    final content = _content.text.trim();
    if (content.isEmpty) return;
    final old = widget.initial;
    Navigator.pop(
      context,
      FixedTagEntry(
        id: old?.id ?? 'fixed${DateTime.now().microsecondsSinceEpoch}',
        name: _name.text.trim(),
        content: content,
        weight: _weight,
        side: _side,
        position: _position,
        enabled: old?.enabled ?? true,
        createdAt: old?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? '新建固定词' : '编辑固定词'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: '名称', isDense: true)),
          const SizedBox(height: 10),
          TextField(
            controller: _content,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: '提示词内容', hintText: '例如 masterpiece, best quality', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<FixedTagSide>(
            initialValue: _side,
            decoration: const InputDecoration(labelText: '作用于', isDense: true),
            items: const [
              DropdownMenuItem(value: FixedTagSide.positive, child: Text('正向提示词')),
              DropdownMenuItem(value: FixedTagSide.negative, child: Text('负向提示词')),
            ],
            onChanged: (value) => setState(() => _side = value ?? _side),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<FixedTagPosition>(
            initialValue: _position,
            decoration: const InputDecoration(labelText: '插入位置', isDense: true),
            items: const [
              DropdownMenuItem(value: FixedTagPosition.prefix, child: Text('提示词前')),
              DropdownMenuItem(value: FixedTagPosition.suffix, child: Text('提示词后')),
            ],
            onChanged: (value) => setState(() => _position = value ?? _position),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('权重'),
              Expanded(child: Slider(value: _weight, min: .5, max: 2, divisions: 30, onChanged: (value) => setState(() => _weight = value))),
              Text(_weight.toStringAsFixed(2), style: mono(context, size: 12)),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _submit, child: const Text('保存')),
    ],
  );
}
