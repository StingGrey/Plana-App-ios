import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/gallery_save.dart';
import '../../core/util/file_read.dart';
import '../../core/util/image_pick.dart';
import '../gallery/gallery_state.dart';
import '../gallery/result_detail_page.dart';
import '../generate/generate_state.dart';
import '../generate/widgets/common.dart'
    show confirmDialog, hintSnack, sharedAxisRoute;
import '../import/import_panel.dart';
import '../inspiration/prompt_library_save.dart';
import '../shell/shell_state.dart';
import 'local_gallery_state.dart';
import 'local_gallery_store.dart';

/// Full local-work gallery inspired by NAI Launcher.
///
/// Catalog view for generated history plus files imported from Photos/Files.
/// Generated entries are metadata-only references to GalleryStore; only external
/// files are copied into local_gallery, so one generated image has one owner.
class LocalGalleryPage extends ConsumerStatefulWidget {
  const LocalGalleryPage({super.key});

  @override
  ConsumerState<LocalGalleryPage> createState() => _LocalGalleryPageState();
}

class _LocalGalleryPageState extends ConsumerState<LocalGalleryPage> {
  final _search = TextEditingController();
  final _selected = <String>{};
  bool _selectionMode = false;
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  LocalGalleryNotifier get _notifier => ref.read(localGalleryProvider.notifier);

  Future<void> _restoreHistory() async {
    final gallery = ref.read(galleryProvider);
    final hidden = [
      for (final result in gallery.results)
        if (ref
            .read(appStoresProvider)
            .localGallery
            .hiddenHistoryIds
            .contains(result.id))
          result,
    ];
    if (hidden.isEmpty || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .75,
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            const ListTile(
              leading: Icon(Icons.history),
              title: Text('从历史记录添加'),
              subtitle: Text('只添加引用，不会复制图片文件'),
            ),
            for (final result in hidden)
              ListTile(
                leading: const Icon(Icons.photo_outlined),
                title: Text(
                  result.seed == 0 ? result.id : 'Seed ${result.seed}',
                ),
                subtitle: Text('${result.width} × ${result.height}'),
                onTap: () {
                  ref
                      .read(localGalleryProvider.notifier)
                      .restoreHistory(result.id);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _import() async {
    if (_busy) return;
    final picked = await pickImagesOrFiles(context);
    if (picked.isEmpty || !mounted) return;
    setState(() => _busy = true);
    var count = await _notifier.importPicked(picked.images);
    for (final file in picked.files) {
      try {
        final bytes = await readPickedBytes(file);
        final before = ref
            .read(appStoresProvider)
            .localGallery
            .initialItems
            .length;
        await ref
            .read(appStoresProvider)
            .localGallery
            .importBytes(bytes, file.name, sourcePath: file.path);
        if (ref.read(appStoresProvider).localGallery.initialItems.length >
            before) {
          count++;
        }
      } catch (_) {}
    }
    _notifier.refreshFromStore();
    if (!mounted) return;
    setState(() => _busy = false);
    hintSnack(
      context,
      count == 0 ? '没有新增图片' : '已加入图库 $count 张图片',
      icon: count == 0 ? Icons.info_outline : Icons.check_circle_outline,
    );
  }

  Future<void> _scanFolder() async {
    if (_busy || Platform.isIOS) return;
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择作品文件夹');
    } catch (error) {
      if (mounted) {
        hintSnack(context, '当前平台无法选择文件夹：$error', icon: Icons.info_outline);
      }
      return;
    }
    if (path == null || !mounted) return;
    setState(() => _busy = true);
    await _notifier.scanDirectory(path);
    if (!mounted) return;
    setState(() => _busy = false);
    final state = ref.read(localGalleryProvider);
    hintSnack(
      context,
      state.error ?? '扫描完成，共 ${state.items.length} 张',
      icon: state.error == null
          ? Icons.check_circle_outline
          : Icons.error_outline,
    );
  }

  void _toggleSelection(String id) {
    setState(() {
      _selectionMode = true;
      if (!_selected.add(id)) _selected.remove(id);
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _leaveSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _selectAll(List<LocalGalleryRecord> items) {
    setState(() {
      _selectionMode = true;
      if (_selected.length == items.length) {
        _selected.clear();
        _selectionMode = false;
      } else {
        _selected
          ..clear()
          ..addAll(items.map((item) => item.id));
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final ok = await confirmDialog(
      context,
      title: '移出 ${_selected.length} 张图片',
      message: '只从本地图库移出。历史记录和外部原文件都不会被删除。',
      confirmLabel: '移出',
    );
    if (!ok || !mounted) return;
    await _notifier.delete(_selected);
    if (mounted) _leaveSelection();
  }

  Future<void> _saveSelected() async {
    final ids = _selected.toSet();
    if (ids.isEmpty || _busy) return;
    final ok = await Gal.hasAccess() || await Gal.requestAccess();
    if (!ok) {
      if (mounted) hintSnack(context, '未获相册权限', icon: Icons.error_outline);
      return;
    }
    setState(() => _busy = true);
    final store = ref.read(appStoresProvider).localGallery;
    var saved = 0;
    for (final item in ref.read(localGalleryProvider).items) {
      if (!ids.contains(item.id)) continue;
      final bytes = await store.readImage(item.id);
      if (bytes == null) continue;
      try {
        await saveImageBytesToGallery(
          bytes,
          name: item.name.isEmpty ? item.id : item.name,
          extension: _extension(item.fileName),
        );
        saved++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _busy = false);
    hintSnack(context, '已保存 $saved 张到相册', icon: Icons.check_circle_outline);
  }

  Future<void> _shareSelected() async {
    final ids = _selected.toSet();
    if (ids.isEmpty || _busy) return;
    setState(() => _busy = true);
    final files = <XFile>[];
    try {
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/plana_local_share',
      );
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      final store = ref.read(appStoresProvider).localGallery;
      for (final item in ref.read(localGalleryProvider).items) {
        if (!ids.contains(item.id)) continue;
        final bytes = await store.readImage(item.id);
        if (bytes == null) continue;
        final ext = _extension(item.fileName);
        final file = File('${dir.path}/${item.id}.$ext');
        await file.writeAsBytes(bytes, flush: true);
        files.add(XFile(file.path, mimeType: 'image/$ext'));
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    if (files.isEmpty) {
      hintSnack(context, '没有可分享的图片', icon: Icons.error_outline);
      return;
    }
    await SharePlus.instance.share(ShareParams(files: files));
  }

  Future<void> _setCategory() async {
    final state = ref.read(localGalleryProvider);
    final value = await _chooseString(
      title: '移动到分类',
      options: state.categories,
      allowCreate: true,
    );
    if (value == null || !mounted) return;
    if (!state.categories.contains(value)) {
      // The store keeps the built-in categories and appends custom ones.
      ref.read(appStoresProvider).localGallery.setCategories([
        ...state.categories,
        value,
      ]);
    }
    _notifier.setCategoryFor(_selected, value);
  }

  Future<void> _manageCollections() async {
    final collections = ref.read(localGalleryProvider).collections;
    if (collections.isEmpty) {
      final name = await _textInput('新建集合', hint: '集合名称');
      if (name != null) {
        _notifier.createCollection(name);
      }
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('管理集合')),
            for (final collection in collections)
              ListTile(
                leading: const Icon(Icons.collections_bookmark_outlined),
                title: Text(collection.name),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    Navigator.pop(ctx);
                    if (value == 'rename') {
                      final name = await _textInput(
                        '重命名集合',
                        hint: collection.name,
                      );
                      if (name != null) {
                        ref
                            .read(appStoresProvider)
                            .localGallery
                            .renameCollection(collection.id, name);
                        _notifier.refreshFromStore();
                      }
                    } else if (value == 'delete') {
                      final ok = await confirmDialog(
                        context,
                        title: '删除集合',
                        message: '只删除集合，不会删除其中的图片。',
                        confirmLabel: '删除',
                      );
                      if (ok) _notifier.deleteCollection(collection.id);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text('删除集合')),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _addCollection() async {
    final state = ref.read(localGalleryProvider);
    if (state.collections.isEmpty) {
      final name = await _textInput('新建集合', hint: '集合名称');
      if (name != null && name.trim().isNotEmpty) {
        final collection = _notifier.createCollection(name);
        _notifier.addToCollection(_selected, collection.id);
      }
      return;
    }
    final value = await _chooseCollection(state.collections);
    if (value == null || !mounted) return;
    if (value == '__new__') {
      final name = await _textInput('新建集合', hint: '集合名称');
      if (name != null && name.trim().isNotEmpty) {
        final collection = _notifier.createCollection(name);
        _notifier.addToCollection(_selected, collection.id);
      }
      return;
    }
    _notifier.addToCollection(_selected, value);
  }

  Future<String?> _chooseCollection(List<LocalGalleryCollection> items) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('加入集合')),
            for (final item in items)
              ListTile(
                leading: const Icon(Icons.collections_bookmark_outlined),
                title: Text(item.name),
                onTap: () => Navigator.pop(ctx, item.id),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建集合'),
              onTap: () => Navigator.pop(ctx, '__new__'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<String?> _chooseString({
    required String title,
    required List<String> options,
    required bool allowCreate,
  }) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(title)),
            for (final option in options)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(option),
                onTap: () => Navigator.pop(ctx, option),
              ),
            if (allowCreate)
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('新建分类'),
                onTap: () => Navigator.pop(ctx, '__new__'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (result != '__new__') return result;
    return _textInput('新建分类', hint: '分类名称');
  }

  Future<String?> _textInput(String title, {required String hint}) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(isDense: true, hintText: hint),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value?.trim();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localGalleryProvider);
    final items = state.filteredItems;
    final scheme = context.scheme;
    final hiddenHistoryCount = ref
        .read(appStoresProvider)
        .localGallery
        .hiddenHistoryIds
        .length;
    return Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text('已选 ${_selected.length}')
            : const Text('本地图库'),
        leading: _selectionMode
            ? IconButton(
                tooltip: '退出多选',
                icon: const Icon(Icons.close),
                onPressed: _leaveSelection,
              )
            : null,
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else ...[
            if (!_selectionMode && !Platform.isIOS)
              IconButton(
                tooltip: '选择文件夹扫描',
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: _scanFolder,
              ),
            IconButton(
              tooltip: '导入图片',
              icon: const Icon(Icons.add_photo_alternate_outlined),
              onPressed: _import,
            ),
            if (!_selectionMode && hiddenHistoryCount > 0)
              IconButton(
                tooltip: '从历史记录添加',
                icon: Badge(
                  label: Text('$hiddenHistoryCount'),
                  child: const Icon(Icons.history),
                ),
                onPressed: _restoreHistory,
              ),
            if (!_selectionMode)
              IconButton(
                tooltip: '管理集合',
                icon: const Icon(Icons.collections_bookmark_outlined),
                onPressed: _manageCollections,
              ),
            if (!_selectionMode)
              IconButton(
                tooltip: '多选',
                icon: const Icon(Icons.checklist_outlined),
                onPressed: () => setState(() => _selectionMode = true),
              ),
          ],
        ],
      ),
      body: Column(
        children: [
          _toolbar(state, scheme),
          if (state.scanning) ...[
            LinearProgressIndicator(
              value: state.scanTotal > 0
                  ? state.scanDone / state.scanTotal
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 5, 14, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  state.scanTotal > 0
                      ? '正在扫描 ${state.scanDone}/${state.scanTotal}'
                      : '正在扫描文件夹…',
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ),
            ),
          ],
          Expanded(child: items.isEmpty ? _empty(state, scheme) : _grid(items)),
        ],
      ),
      bottomNavigationBar: _selectionMode && _selected.isNotEmpty
          ? _selectionBar(items, scheme)
          : null,
    );
  }

  Widget _toolbar(LocalGalleryState state, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 5),
      child: Column(
        children: [
          TextField(
            controller: _search,
            onChanged: _notifier.setQuery,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索 Prompt、模型、标签或文件名…',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: state.query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _search.clear();
                        _notifier.setQuery('');
                      },
                    ),
              filled: true,
              fillColor: scheme.surfaceContainerHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _filterChip(
                  label: '全部 ${state.items.length}',
                  selected: !state.hasFilters,
                  onTap: _notifier.clearFilters,
                ),
                const SizedBox(width: 7),
                _filterChip(
                  label: '收藏',
                  selected: state.favoritesOnly,
                  icon: Icons.star_outline,
                  onTap: _notifier.toggleFavoritesOnly,
                ),
                const SizedBox(width: 7),
                for (final category in state.categories) ...[
                  _filterChip(
                    label: category,
                    selected: state.category == category,
                    onTap: () => _notifier.setCategory(
                      state.category == category ? null : category,
                    ),
                  ),
                  const SizedBox(width: 7),
                ],
                _filterChip(
                  label: state.dateDays == 0 ? '时间' : '近 ${state.dateDays} 天',
                  selected: state.dateDays > 0,
                  icon: Icons.date_range_outlined,
                  onTap: _pickDateFilter,
                ),
                const SizedBox(width: 7),
                if (state.collections.isNotEmpty) ...[
                  _filterChip(
                    label: '集合',
                    selected: state.collectionId != null,
                    icon: Icons.collections_bookmark_outlined,
                    onTap: () async {
                      final id = await _chooseCollectionFilter(
                        state.collections,
                      );
                      if (id != null) _notifier.setCollection(id);
                    },
                  ),
                ],
              ],
            ),
          ),
          if (state.hasFilters)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _notifier.clearFilters,
                icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
                label: Text('清除筛选 · ${state.filteredItems.length} 张'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickDateFilter() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('按日期筛选')),
            for (final days in const [0, 1, 7, 30])
              ListTile(
                leading: const Icon(Icons.date_range_outlined),
                title: Text(
                  days == 0 ? '全部日期' : (days == 1 ? '今天' : '近 $days 天'),
                ),
                onTap: () => Navigator.pop(ctx, days),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) _notifier.setDateDays(picked);
  }

  Future<String?> _chooseCollectionFilter(
    List<LocalGalleryCollection> collections,
  ) => showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('按集合筛选')),
          for (final c in collections)
            ListTile(
              leading: const Icon(Icons.collections_bookmark_outlined),
              title: Text(c.name),
              onTap: () => Navigator.pop(ctx, c.id),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return FilterChip(
      selected: selected,
      label: Text(label),
      avatar: icon == null ? null : Icon(icon, size: 15),
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      showCheckmark: false,
    );
  }

  Widget _grid(List<LocalGalleryRecord> items) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 155)
            .floor()
            .clamp(2, 6)
            .toInt();
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 5, 12, 18),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 9,
            crossAxisSpacing: 9,
            childAspectRatio: .76,
          ),
          itemCount: items.length,
          itemBuilder: (_, index) => _LocalGalleryCard(
            item: items[index],
            selected: _selected.contains(items[index].id),
            selectionMode: _selectionMode,
            onTap: () {
              if (_selectionMode) {
                _toggleSelection(items[index].id);
                return;
              }
              final item = items[index];
              final history = item.historyId == null
                  ? null
                  : ref
                        .read(galleryProvider)
                        .results
                        .where((result) => result.id == item.historyId)
                        .firstOrNull;
              Navigator.of(context).push(
                sharedAxisRoute(
                  history == null
                      ? LocalGalleryDetailPage(item: item)
                      : ResultDetailPage(result: history),
                ),
              );
            },
            onLongPress: () => _toggleSelection(items[index].id),
            onFavorite: () => _notifier.toggleFavorite(items[index].id),
          ),
        );
      },
    );
  }

  Widget _empty(LocalGalleryState state, ColorScheme scheme) {
    final filtered = state.hasFilters;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered
                  ? Icons.filter_alt_off_outlined
                  : Icons.photo_library_outlined,
              size: 56,
              color: scheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text(
              filtered ? '没有匹配的作品' : '本地图库还是空的',
              style: context.texts.titleMedium!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              filtered ? '调整搜索或筛选条件' : '历史记录会自动显示，也可导入外部图片',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall!.copyWith(color: scheme.outline),
            ),
            if (!filtered) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('导入图片'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _selectionBar(List<LocalGalleryRecord> visible, ColorScheme scheme) {
    return SafeArea(
      child: Material(
        color: scheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 8),
          child: Wrap(
            spacing: 7,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () => _selectAll(visible),
                icon: const Icon(Icons.select_all, size: 18),
                label: Text(_selected.length == visible.length ? '取消全选' : '全选'),
              ),
              _actionPill(Icons.download_outlined, '保存', _saveSelected),
              _actionPill(Icons.share_outlined, '分享', _shareSelected),
              _actionPill(Icons.folder_outlined, '分类', _setCategory),
              _actionPill(Icons.star_outline, '收藏', () {
                final allFavorite = _selected.every(
                  (id) =>
                      ref
                          .read(localGalleryProvider)
                          .items
                          .where((item) => item.id == id)
                          .firstOrNull
                          ?.favorite ==
                      true,
                );
                _notifier.setFavoriteFor(_selected, !allFavorite);
              }),
              _actionPill(
                Icons.collections_bookmark_outlined,
                '集合',
                _addCollection,
              ),
              _actionPill(
                Icons.remove_circle_outline,
                '移出',
                _deleteSelected,
                danger: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionPill(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    final color = danger
        ? context.scheme.error
        : context.scheme.onSurfaceVariant;
    return ActionChip(
      avatar: Icon(icon, size: 17, color: color),
      label: Text(label),
      onPressed: _busy ? null : onTap,
      labelStyle: TextStyle(color: color),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _LocalGalleryCard extends ConsumerWidget {
  const _LocalGalleryCard({
    required this.item,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onFavorite,
  });

  final LocalGalleryRecord item;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12),
                    ),
                    child: _LocalThumb(id: item.id, fit: BoxFit.cover),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(9, 6, 6, 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodySmall!.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (!selectionMode)
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: IconButton(
                            tooltip: item.favorite ? '取消收藏' : '收藏',
                            padding: EdgeInsets.zero,
                            onPressed: onFavorite,
                            icon: Icon(
                              item.favorite ? Icons.star : Icons.star_border,
                              size: 18,
                              color: item.favorite
                                  ? Colors.amber.shade700
                                  : scheme.outline,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (item.hasMetadata)
              Positioned(
                top: 7,
                right: 7,
                child: _Badge(label: 'META', color: scheme.primary),
              ),
            if (item.category != '未分类')
              Positioned(
                left: 7,
                bottom: 42,
                child: _Badge(
                  label: item.category,
                  color: Colors.black.withValues(alpha: .62),
                ),
              ),
            if (selected)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .18),
                    border: Border.all(color: scheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            if (selectionMode)
              Positioned(
                top: 7,
                left: 7,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? scheme.primary
                        : Colors.black.withValues(alpha: .45),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .85),
                    ),
                  ),
                  child: selected
                      ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LocalThumb extends ConsumerWidget {
  const _LocalThumb({required this.id, required this.fit});

  final String id;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(localGalleryThumbProvider(id));
    return async.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, _) => ColoredBox(
        color: context.scheme.surfaceContainerHigh,
        child: Icon(Icons.broken_image_outlined, color: context.scheme.outline),
      ),
      data: (bytes) => bytes == null
          ? ColoredBox(
              color: context.scheme.surfaceContainerHigh,
              child: Icon(
                Icons.broken_image_outlined,
                color: context.scheme.outline,
              ),
            )
          : Image.memory(bytes, fit: fit, gaplessPlayback: true),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 9,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class LocalGalleryDetailPage extends ConsumerWidget {
  const LocalGalleryDetailPage({super.key, required this.item});

  final LocalGalleryRecord item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final store = ref.read(appStoresProvider).localGallery;
    return Scaffold(
      appBar: AppBar(
        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: item.favorite ? '取消收藏' : '收藏',
            icon: Icon(item.favorite ? Icons.star : Icons.star_border),
            onPressed: () =>
                ref.read(localGalleryProvider.notifier).toggleFavorite(item.id),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) async {
              if (value == 'import') {
                final bytes = await store.readImage(item.id);
                if (bytes == null || !context.mounted) return;
                await Navigator.of(context).push(
                  sharedAxisRoute(
                    ImportImagePanel(
                      bytes: bytes,
                      fileName: item.fileName,
                      displayName: item.name,
                    ),
                  ),
                );
              }
              if (value == 'copy') {
                await Clipboard.setData(ClipboardData(text: item.prompt));
                if (context.mounted) {
                  hintSnack(context, '已复制提示词', icon: Icons.copy);
                }
              }
              if (value == 'library') {
                if (!context.mounted) return;
                await _savePromptToLibrary(context, ref);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'import', child: Text('导入参数 / 用作参考')),
              const PopupMenuItem(value: 'copy', child: Text('复制正向提示词')),
              if (item.prompt.isNotEmpty)
                const PopupMenuItem(value: 'library', child: Text('保存提示词到词库')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: item.prompt.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                child: FilledButton.icon(
                  onPressed: () => _loadToCreate(context, ref),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('将参数载入创作页'),
                ),
              ),
            ),
      body: FutureBuilder<Uint8List?>(
        future: store.readImage(item.id),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          return _detailBody(context, scheme, bytes);
        },
      ),
    );
  }

  Widget _detailBody(
    BuildContext context,
    ColorScheme scheme,
    Uint8List? bytes,
  ) {
    final sections = <Widget>[
      _detailHeader(context, scheme),
      if (item.prompt.isNotEmpty) ...[
        const SizedBox(height: 18),
        _copyBlock(context, '正向提示词', item.prompt, scheme, danger: false),
      ],
      if (item.negativePrompt.isNotEmpty) ...[
        const SizedBox(height: 14),
        _copyBlock(context, '负向提示词', item.negativePrompt, scheme, danger: true),
      ],
      if (item.characters.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          '角色提示词',
          style: context.texts.titleSmall!.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 7),
        for (var i = 0; i < item.characters.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: _copyBlock(
              context,
              '角色 ${i + 1}',
              item.characters[i].prompt,
              scheme,
              danger: false,
              compact: true,
            ),
          ),
      ],
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 700) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: [
              _detailImage(scheme, bytes),
              const SizedBox(height: 16),
              ...sections,
            ],
          );
        }
        final availableHeight = constraints.hasBoundedHeight
            ? math.max(0.0, constraints.maxHeight - 32)
            : MediaQuery.sizeOf(context).height;
        // Keep tall images from pushing the parameter pane below the fold.
        final maxImageHeight = math.min(
          availableHeight,
          MediaQuery.sizeOf(context).height * .82,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 560,
                      maxHeight: maxImageHeight,
                    ),
                    child: _detailImage(scheme, bytes),
                  ),
                ),
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: scheme.outlineVariant,
            ),
            Expanded(
              flex: 6,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '参数与提示词',
                      style: context.texts.titleMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...sections,
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _detailImage(ColorScheme scheme, Uint8List? bytes) => AspectRatio(
    aspectRatio: item.aspect,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: bytes == null
          ? const Center(child: CircularProgressIndicator())
          : ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
    ),
  );

  Future<void> _savePromptToLibrary(BuildContext context, WidgetRef ref) async {
    final saved = await savePromptToTagLibrary(
      context,
      ref,
      prompt: item.prompt,
      negative: item.negativePrompt,
      suggestedName: item.name,
    );
    if (saved && context.mounted) {
      hintSnack(context, '已保存到词库', icon: Icons.bookmark_added_outlined);
    }
  }

  Future<void> _loadToCreate(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(generateProvider.notifier);
    notifier.setPrompts(positive: item.prompt, negative: item.negativePrompt);
    notifier.applyImportedSettings(
      model: _supportedModelFromLabel(item.model),
      width: item.width > 0 ? item.width : null,
      height: item.height > 0 ? item.height : null,
      steps: item.steps > 0 ? item.steps : null,
      seed: item.seed.isEmpty ? null : item.seed,
    );
    if (item.hasMetadata) notifier.clearCharacters();
    if (item.characters.isNotEmpty) {
      notifier.addCharactersFrom([
        for (final character in item.characters)
          (
            positive: character.prompt,
            negative: character.negativePrompt,
            position: null,
          ),
      ], replace: true);
    }
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
    Navigator.of(context).pop();
  }

  Widget _detailHeader(BuildContext context, ColorScheme scheme) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _InfoTile(label: '尺寸', value: '${item.width} × ${item.height}'),
      _InfoTile(label: '大小', value: _formatBytes(item.sizeBytes)),
      if (item.model.isNotEmpty) _InfoTile(label: '模型', value: item.model),
      if (item.sampler.isNotEmpty) _InfoTile(label: '采样器', value: item.sampler),
      if (item.steps > 0) _InfoTile(label: '步数', value: '${item.steps}'),
      if (item.seed.isNotEmpty) _InfoTile(label: 'Seed', value: item.seed),
      _InfoTile(label: '分类', value: item.category),
    ],
  );

  Widget _copyBlock(
    BuildContext context,
    String title,
    String text,
    ColorScheme scheme, {
    required bool danger,
    bool compact = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            title,
            style: context.texts.labelLarge!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '复制',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) hintSnack(context, '已复制', icon: Icons.check);
            },
          ),
        ],
      ),
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 10 : 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          text,
          style: context.texts.bodySmall!.copyWith(
            height: 1.55,
            color: danger ? scheme.error : scheme.onSurface,
          ),
        ),
      ),
    ],
  );
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 90, maxWidth: 220),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: context.scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.texts.labelSmall!.copyWith(
            color: context.scheme.outline,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.texts.bodySmall,
        ),
      ],
    ),
  );
}

String _extension(String name) {
  final match = RegExp(r'\.([A-Za-z0-9]+)$').firstMatch(name);
  return match?.group(1)?.toLowerCase() == 'jpeg'
      ? 'jpg'
      : (match?.group(1)?.toLowerCase() ?? 'png');
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}

String? _supportedModelFromLabel(String value) {
  final label = value.toLowerCase();
  if (label.contains('v5')) {
    return label.contains('full') ? 'NAI 5.0 Full' : 'NAI 5.0 Curated';
  }
  if (label.contains('4.5')) {
    return label.contains('curated') ? 'NAI 4.5 Curated' : 'NAI 4.5 Full';
  }
  if (RegExp(r'\\bv4\\b').hasMatch(label)) {
    return label.contains('curated') ? 'NAI 4.0 Curated' : 'NAI 4.0 Full';
  }
  return null;
}
