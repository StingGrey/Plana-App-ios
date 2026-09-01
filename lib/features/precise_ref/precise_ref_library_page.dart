import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/file_read.dart';
import '../../core/util/image_pick.dart';
import '../char_library/char_library.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart' show CharRefMode, crSupportsModel;
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;
import '../shell/shell_state.dart';
import 'precise_ref_library.dart';

/// Reusable Precise Reference image library.
class PreciseRefLibraryPage extends ConsumerStatefulWidget {
  const PreciseRefLibraryPage({super.key});

  @override
  ConsumerState<PreciseRefLibraryPage> createState() =>
      _PreciseRefLibraryPageState();
}

class _PreciseRefLibraryPageState extends ConsumerState<PreciseRefLibraryPage> {
  final _search = TextEditingController();
  String _query = '';
  PreciseRefType? _type;
  bool _favoritesOnly = false;
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  PreciseRefNotifier get _notifier => ref.read(preciseRefProvider.notifier);

  Future<void> _import() async {
    if (_busy) return;
    final picked = await pickImagesOrFiles(context);
    if (picked.isEmpty || !mounted) return;
    setState(() => _busy = true);
    var count = 0;
    for (final file in picked.images) {
      try {
        await _notifier.importBytes(
          file.bytes,
          name: file.baseName,
          type: _type ?? PreciseRefType.characterAndStyle,
        );
        count++;
      } catch (_) {}
    }
    for (final file in picked.files) {
      try {
        final bytes = await readPickedBytes(file);
        await _notifier.importBytes(
          bytes,
          name: file.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
          type: _type ?? PreciseRefType.characterAndStyle,
        );
        count++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _busy = false);
    hintSnack(context, '已导入 $count 张精准参考图', icon: Icons.check_circle_outline);
  }

  List<PreciseRefEntry> _filtered(List<PreciseRefEntry> entries) {
    final q = _query.trim().toLowerCase();
    final result = [
      for (final entry in entries)
        if ((_type == null || entry.type == _type) &&
            (!_favoritesOnly || entry.favorite) &&
            (q.isEmpty || entry.name.toLowerCase().contains(q))) entry,
    ];
    result.sort((a, b) => b.recency.compareTo(a.recency));
    return result;
  }

  Future<void> _edit(PreciseRefEntry entry) async {
    final next = await showDialog<({String name, PreciseRefType type, double strength, double fidelity})>(
      context: context,
      builder: (_) => _PreciseRefEditor(entry: entry),
    );
    if (next == null) return;
    await _notifier.updateEntry(
      entry.id,
      name: next.name,
      type: next.type,
      strength: next.strength,
      fidelity: next.fidelity,
    );
  }

  Future<void> _delete(PreciseRefEntry entry) async {
    final ok = await confirmDialog(
      context,
      title: '删除精准参考',
      message: '「${entry.name}」将从本地资源库删除，不影响原始图片。',
      confirmLabel: '删除',
    );
    if (ok) await _notifier.delete(entry.id);
  }

  Future<void> _send(PreciseRefEntry entry) async {
    final model = ref.read(generateProvider).params.model;
    if (!crSupportsModel(model)) {
      hintSnack(context, '$model 不支持精准参考，请先切换到 NAI 4.5', icon: Icons.info_outline);
      return;
    }
    final bytes = await _notifier.loadBytes(entry);
    if (!mounted) return;
    if (bytes == null) {
      hintSnack(context, '参考图文件不存在', icon: Icons.error_outline);
      return;
    }
    CharRefEntry? stored;
    try {
      stored = await ref
          .read(charLibraryProvider.notifier)
          .importImageBytes(bytes, entry.name);
    } catch (_) {}
    if (!mounted) return;
    final id = ref.read(generateProvider.notifier).addCharRef(
      image: bytes,
      name: entry.name,
      imageHash: stored?.id,
    );
    final mode = switch (entry.type) {
      PreciseRefType.character => CharRefMode.character,
      PreciseRefType.style => CharRefMode.style,
      PreciseRefType.characterAndStyle => CharRefMode.both,
    };
    ref.read(generateProvider.notifier).updateCharRef(
      id,
      mode: mode,
      strength: entry.strength,
      // Existing payload calls this field informationExtracted; the UI value
      // is the user-facing fidelity, so the mapping is direct.
      infoExtracted: entry.fidelity,
    );
    unawaited(_notifier.recordUse(entry.id));
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(preciseRefProvider);
    final scheme = context.scheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('精准参考库'),
        actions: [
          IconButton(
            tooltip: _favoritesOnly ? '显示全部' : '只看收藏',
            icon: Icon(_favoritesOnly ? Icons.star : Icons.star_border),
            onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            IconButton(tooltip: '导入图片', icon: const Icon(Icons.add_photo_alternate_outlined), onPressed: _import),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (entries) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 5),
              child: TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索参考图名称…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: scheme.surfaceContainerHigh,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
            SizedBox(
              height: 38,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                scrollDirection: Axis.horizontal,
                children: [
                  _typeChip('全部', null),
                  for (final type in PreciseRefType.values) _typeChip(type.label, type),
                ],
              ),
            ),
            Expanded(child: _grid(_filtered(entries))),
          ],
        ),
      ),
    );
  }

  Widget _typeChip(String label, PreciseRefType? type) => Padding(
    padding: const EdgeInsets.only(right: 7),
    child: ChoiceChip(
      label: Text(label),
      selected: _type == type,
      onSelected: (_) => setState(() => _type = type),
      visualDensity: VisualDensity.compact,
      showCheckmark: false,
    ),
  );

  Widget _grid(List<PreciseRefEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.center_focus_strong, size: 52, color: context.scheme.outlineVariant),
            const SizedBox(height: 10),
            Text(_query.isEmpty && !_favoritesOnly ? '还没有精准参考图' : '没有匹配的资源', style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            if (_query.isEmpty && !_favoritesOnly)
              FilledButton.icon(onPressed: _import, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('导入图片')),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 160).floor().clamp(2, 6).toInt();
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 18),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 9,
            crossAxisSpacing: 9,
            childAspectRatio: .76,
          ),
          itemCount: entries.length,
          itemBuilder: (_, index) => _PreciseRefCard(
            entry: entries[index],
            onTap: () => _send(entries[index]),
            onFavorite: () => _notifier.toggleFavorite(entries[index].id),
            onEdit: () => _edit(entries[index]),
            onDelete: () => _delete(entries[index]),
          ),
        );
      },
    );
  }
}

class _PreciseRefCard extends ConsumerWidget {
  const _PreciseRefCard({
    required this.entry,
    required this.onTap,
    required this.onFavorite,
    required this.onEdit,
    required this.onDelete,
  });

  final PreciseRefEntry entry;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final thumb = ref.watch(preciseRefThumbProvider(entry.id));
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: thumb.when(
                    loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    error: (_, _) => ColoredBox(color: scheme.surfaceContainerHigh, child: Icon(Icons.broken_image_outlined, color: scheme.outline)),
                    data: (bytes) => bytes == null
                        ? ColoredBox(color: scheme.surfaceContainerHigh, child: Icon(Icons.broken_image_outlined, color: scheme.outline))
                        : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 5, 7),
                  child: Row(
                    children: [
                      Expanded(child: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.texts.labelMedium!.copyWith(fontWeight: FontWeight.w600))),
                      Icon(entry.favorite ? Icons.star : Icons.star_border, size: 16, color: entry.favorite ? Colors.amber.shade700 : scheme.outline),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(left: 6, top: 6, child: Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: scheme.primary.withValues(alpha: .9), borderRadius: BorderRadius.circular(5)), child: Text(entry.type.label, style: TextStyle(color: scheme.onPrimary, fontSize: 9, fontWeight: FontWeight.w700)))),
            Positioned(
              right: 1,
              top: 1,
              child: PopupMenuButton<String>(
                tooltip: '资源操作',
                icon: const Icon(Icons.more_horiz, color: Colors.white, shadows: [Shadow(blurRadius: 3, color: Colors.black54)]),
                onSelected: (value) {
                  if (value == 'favorite') onFavorite();
                  if (value == 'edit') onEdit();
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'favorite', child: Text(entry.favorite ? '取消收藏' : '收藏')),
                  const PopupMenuItem(value: 'edit', child: Text('编辑参数')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreciseRefEditor extends StatefulWidget {
  const _PreciseRefEditor({required this.entry});

  final PreciseRefEntry entry;

  @override
  State<_PreciseRefEditor> createState() => _PreciseRefEditorState();
}

class _PreciseRefEditorState extends State<_PreciseRefEditor> {
  late final TextEditingController _name;
  late PreciseRefType _type;
  late double _strength;
  late double _fidelity;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.entry.name);
    _type = widget.entry.type;
    _strength = widget.entry.strength;
    _fidelity = widget.entry.fidelity;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑精准参考'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: '名称', isDense: true)),
        const SizedBox(height: 10),
        DropdownButtonFormField<PreciseRefType>(
          initialValue: _type,
          decoration: const InputDecoration(labelText: '参考类型', isDense: true),
          items: [for (final type in PreciseRefType.values) DropdownMenuItem(value: type, child: Text(type.label))],
          onChanged: (value) => setState(() => _type = value ?? _type),
        ),
        const SizedBox(height: 7),
        _slider('强度', _strength, (value) => setState(() => _strength = value)),
        _slider('保真度', _fidelity, (value) => setState(() => _fidelity = value)),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        onPressed: () => Navigator.pop(context, (name: _name.text.trim(), type: _type, strength: _strength, fidelity: _fidelity)),
        child: const Text('保存'),
      ),
    ],
  );

  Widget _slider(String label, double value, ValueChanged<double> onChanged) => Row(
    children: [
      SizedBox(width: 48, child: Text(label)),
      Expanded(child: Slider(value: value, min: 0, max: 1, divisions: 20, onChanged: onChanged)),
      Text(value.toStringAsFixed(2), style: mono(context, size: 11)),
    ],
  );
}
