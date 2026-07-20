import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_theme.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart';
import '../generate/widgets/common.dart';
import 'char_library.dart';

/// 角色参考图库(仅「我的」本地库)。交互对齐 Vibe 管理器:
/// 点卡 = 加入/移出生成面板(勾选态),底栏「删除 / 清空 / 取消 / 确认选择」,
/// 卡片右上菜单 = 重命名 / 删除。生成页导入的参考图会自动收藏在此。
class CharLibraryPage extends ConsumerStatefulWidget {
  const CharLibraryPage({super.key});

  @override
  ConsumerState<CharLibraryPage> createState() => _CharLibraryPageState();
}

class _CharLibraryPageState extends ConsumerState<CharLibraryPage> {
  /// 进入页面时的角色参考快照(「取消」放弃本次全部增删还原它)。
  late final List<CharRefItem> _snapshot;
  // 加入角色参考会因互斥停用 Vibe,快照一并保存,「取消」时连同还原。
  late final List<VibeItem> _vibesSnapshot;
  String _search = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _snapshot = List.of(ref.read(generateProvider).charRefs);
    _vibesSnapshot = List.of(ref.read(generateProvider).vibes);
  }

  CharLibrary get _lib => ref.read(charLibraryProvider.notifier);

  // ---- 勾选语义:已加入生成面板(库条目 id 即图片内容哈希,与生成项 imageHash 对齐)----

  String? _activeItemId(CharRefEntry e) {
    for (final r in ref.read(generateProvider).charRefs) {
      if (r.imageHash == e.id) return r.id;
    }
    return null;
  }

  Future<void> _toggle(CharRefEntry e) async {
    final activeId = _activeItemId(e);
    if (activeId != null) {
      ref.read(generateProvider.notifier).removeCharRef(activeId);
      setState(() {});
      return;
    }
    final bytes = await _lib.loadImageBytes(e);
    if (!mounted) return;
    if (bytes == null) {
      hintSnack(context, '无法读取该参考图', icon: Icons.error_outline);
      return;
    }
    HapticFeedback.selectionClick();
    final hadVibes = ref.read(generateProvider).enabledVibes > 0;
    ref
        .read(generateProvider.notifier)
        .addCharRef(image: bytes, name: e.name, imageHash: e.id);
    if (hadVibes) {
      hintSnack(context, '与 Vibe 互斥,已暂停 Vibe 参考', icon: Icons.swap_horiz);
    }
    setState(() {});
  }

  // ---- 底部批量操作(作用于已勾选 = 已加入生成的库条目)----

  List<CharRefEntry> _checkedEntries(List<CharRefEntry> all) =>
      [for (final e in all) if (_activeItemId(e) != null) e];

  Future<void> _deleteChecked(List<CharRefEntry> checked) async {
    final ok = await confirmDialog(
      context,
      title: '删除参考图',
      message: '将从库中删除选中的 ${checked.length} 张(文件与缩略图一并移除),不可恢复。',
      confirmLabel: '删除',
    );
    if (!ok || !mounted) return;
    for (final e in checked) {
      final activeId = _activeItemId(e);
      if (activeId != null) {
        ref.read(generateProvider.notifier).removeCharRef(activeId);
      }
      await _lib.delete(e.id);
    }
    if (mounted) setState(() {});
  }

  void _clearActive() {
    final notifier = ref.read(generateProvider.notifier);
    for (final r in [...ref.read(generateProvider).charRefs]) {
      notifier.removeCharRef(r.id);
    }
    setState(() {});
  }

  /// 取消:还原进入页面时的快照(放弃本次全部勾选增删,含被互斥停用的 Vibe),返回生成页。
  void _cancel() {
    ref.read(generateProvider.notifier)
      ..restoreCharRefs(_snapshot)
      ..restoreVibes(_vibesSnapshot);
    Navigator.of(context).pop();
  }

  /// 确认选择:点卡时已实时加入生成面板,这里直接返回。
  void _confirm() => Navigator.of(context).pop();

  // ---- 单卡菜单 ----

  Future<void> _rename(CharRefEntry e) async {
    final ctrl = TextEditingController(text: e.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(isDense: true, hintText: '参考图名称'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _lib.rename(e.id, name);
    }
  }

  Future<void> _deleteOne(CharRefEntry e) async {
    final ok = await confirmDialog(
      context,
      title: '删除参考图',
      message: '「${e.name}」将从图库移除(不影响已添加到生成面板的),不可恢复。',
      confirmLabel: '删除',
    );
    if (!ok) return;
    final activeId = _activeItemId(e);
    if (activeId != null) {
      ref.read(generateProvider.notifier).removeCharRef(activeId);
    }
    await _lib.delete(e.id);
    if (mounted) setState(() {});
  }

  // ---- 导入(右上角 +)----

  Future<void> _importImages() async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty || !mounted) return;
    setState(() => _busy = true);
    var n = 0;
    for (final f in files) {
      try {
        await _lib.importImageBytes(
            await f.readAsBytes(), f.name.replaceAll(RegExp(r'\.[^.]+$'), ''));
        n++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _busy = false);
    hintSnack(context, '已入库 $n 张参考图', icon: Icons.check_circle_outline);
  }

  // ---- 列表数据 ----

  List<CharRefEntry> _visible(List<CharRefEntry> all) {
    final q = _search.trim().toLowerCase();
    final list = [
      for (final e in all)
        if (q.isEmpty || e.name.toLowerCase().contains(q)) e,
    ];
    list.sort((a, b) => b.recency.compareTo(a.recency));
    return list;
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final all = ref.watch(charLibraryProvider).value;
    final activeCount = ref.watch(generateProvider).charRefs.length;
    final checked = all == null ? const <CharRefEntry>[] : _checkedEntries(all);

    return Scaffold(
      appBar: AppBar(
        title: const Text('角色参考图库'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              tooltip: '导入图片',
              icon: const Icon(Icons.add),
              onPressed: _importImages,
            ),
        ],
      ),
      body: Column(
        children: [
          // 搜索
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索名称…',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: scheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          Expanded(
            child: all == null
                ? const Center(child: CircularProgressIndicator())
                : _grid(_visible(all)),
          ),
        ],
      ),
      bottomNavigationBar: _bottomBar(scheme, checked, activeCount),
    );
  }

  Widget _grid(List<CharRefEntry> list) {
    final scheme = context.scheme;
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.face_retouching_natural,
                size: 44, color: scheme.outlineVariant),
            const SizedBox(height: 10),
            Text(
              _search.isEmpty ? '还没有角色参考图' : '没有匹配的参考图',
              style: context.texts.bodySmall!
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
            if (_search.isEmpty) ...[
              const SizedBox(height: 4),
              Text('在生成页导入参考图后会自动收藏到这里',
                  style: context.texts.labelSmall!
                      .copyWith(color: scheme.outline)),
            ],
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.82,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final e = list[i];
        return _CharCard(
          entry: e,
          checked: _activeItemId(e) != null,
          thumb: _lib.thumbOf(e),
          onTap: () => _toggle(e),
          onRename: () => _rename(e),
          onDelete: () => _deleteOne(e),
        );
      },
    );
  }

  Widget _bottomBar(
      ColorScheme scheme, List<CharRefEntry> checked, int activeCount) {
    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 第一层:批量删除(左,勾选后浮现)+ 清空(右)
              Row(
                children: [
                  if (checked.isNotEmpty)
                    _pillBtn(
                      icon: Icons.delete_outline,
                      label: '删除',
                      color: scheme.error,
                      onTap: () => _deleteChecked(checked),
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: activeCount == 0 ? null : _clearActive,
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.error,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('清空'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 第二层:取消(还原快照)+ 确认选择
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _cancel,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 46),
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(23),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _confirm,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(23),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      icon: const Icon(Icons.check, size: 19),
                      label: Text(
                        activeCount > 0 ? '确认选择 ($activeCount)' : '确认选择',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 批量行的小描边按钮(图标 + 文字)。
  Widget _pillBtn({
    required IconData icon,
    required String label,
    Color? color,
    VoidCallback? onTap,
  }) {
    final scheme = context.scheme;
    final enabled = onTap != null;
    final fg =
        (color ?? scheme.onSurfaceVariant).withValues(alpha: enabled ? 1 : .45);
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(
          color: color != null
              ? color.withValues(alpha: .5)
              : scheme.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 5),
              Text(
                label,
                style: context.texts.labelMedium!.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 本地卡片:点卡 = 加入/移出生成;右上菜单 = 重命名 / 删除。外观对齐 Vibe 卡。
class _CharCard extends StatelessWidget {
  const _CharCard({
    required this.entry,
    required this.checked,
    required this.thumb,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final CharRefEntry entry;
  final bool checked;
  final File thumb;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      decoration: BoxDecoration(
        color: checked
            ? scheme.primaryContainer.withValues(alpha: .28)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      // 边框放前景层:选中态加粗高亮只是绘制,不占布局。
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: checked
              ? scheme.primary.withValues(alpha: .7)
              : scheme.outlineVariant.withValues(alpha: .3),
          width: checked ? 1.8 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 缩略图区(占卡片上部剩余空间)
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    thumb,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => ColoredBox(
                      color: scheme.surfaceContainerHigh,
                      child: Icon(Icons.broken_image_outlined,
                          color: scheme.outline),
                    ),
                  ),
                  if (checked)
                    Container(color: scheme.primary.withValues(alpha: .18)),
                  Positioned(top: 8, left: 8, child: _checkbox(scheme)),
                ],
              ),
            ),
            // 卡片体:名称 + 右侧更多菜单
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodyMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                        color: checked ? scheme.primary : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  _CharMenuButton(
                    onSelected: (v) => v == 'rename' ? onRename() : onDelete(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _checkbox(ColorScheme scheme) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: checked ? scheme.primary : Colors.black.withValues(alpha: .3),
        border: Border.all(
          color: checked ? scheme.primary : Colors.white.withValues(alpha: .85),
          width: 2,
        ),
      ),
      child: checked
          ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
          : null,
    );
  }
}

/// 名称行右侧的紧凑「更多」菜单按钮(重命名 / 删除)。
class _CharMenuButton extends StatelessWidget {
  const _CharMenuButton({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SizedBox(
      width: 30,
      height: 22,
      child: PopupMenuButton<String>(
        tooltip: '更多',
        icon: Icon(Icons.more_vert, size: 20, color: scheme.onSurfaceVariant),
        padding: EdgeInsets.zero,
        iconSize: 20,
        onSelected: onSelected,
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'rename',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.drive_file_rename_outline, size: 19),
              title: Text('重命名'),
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, size: 19, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
            ),
          ),
        ],
      ),
    );
  }
}
