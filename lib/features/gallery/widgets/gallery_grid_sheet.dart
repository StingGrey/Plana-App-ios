import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../../../core/store/app_stores.dart';
import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart'
    show ExpandBody, confirmDialog, hintSnack, sharedAxisRoute;
import '../../import/import_panel.dart';
import '../gallery_dates.dart';
import '../gallery_search.dart';
import '../gallery_state.dart';
import '../models.dart';
import '../save_pipeline.dart';
import '../save_settings.dart';
import 'album_name_sheet.dart';
import 'result_badge_chip.dart';
import 'result_thumb.dart';
import '../../../core/util/haptics.dart';

/// 「›」展开:全部作品网格弹层,按天分段显示;可按模型/时间筛选、按提示词
/// 标签搜索(数据源 gallery_search 检索索引,筛选条件全 AND 组合)。
/// 点选一张即回填画布并关闭;长按弹出该张的导入 / 保存 / 删除菜单。
/// 多选只从右上角「多选」进,段头可整段全选,底部批量保存相册 / 批量删除
/// —— 批量操作只作用于当前可见集合。
/// [selectId] 传入时直接以多选态打开并预选该张(胶片条长按入口)。
Future<void> showGalleryGrid(BuildContext context, {String? selectId}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GalleryGridSheet(initialSelectId: selectId),
    );

class _GalleryGridSheet extends ConsumerStatefulWidget {
  const _GalleryGridSheet({this.initialSelectId});

  final String? initialSelectId;

  @override
  ConsumerState<_GalleryGridSheet> createState() => _GalleryGridSheetState();
}

class _GalleryGridSheetState extends ConsumerState<_GalleryGridSheet> {
  bool _selecting = false;
  final Set<String> _picked = {};
  bool _saving = false;
  int _saveDone = 0;
  int _saveTotal = 0;

  // ---- 检索/筛选(弹层内临时态,关弹层即重置) ----
  final _searchCtrl = TextEditingController();
  // 焦点显式管理:搜索框在 ExpandBody 里是**常驻构建**的(只是高度收成 0),
  // 用 autofocus 会在弹层一打开就抢焦点弹键盘 —— 用户还没想搜。
  final _searchFocus = FocusNode();
  Timer? _searchDebounce;
  bool _searchOpen = false;
  String _query = '';
  String? _modelFilter; // null=全部;''=未知(无参数快照的老图)
  int _daysFilter = 0; // 0=全部 / 1=今天 / 7=近7天 / 30=近30天

  @override
  void initState() {
    super.initState();
    final pre = widget.initialSelectId;
    if (pre != null) {
      _selecting = true;
      _picked.add(pre);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchCtrl.clear();
        _query = '';
      }
    });
    // 只有明确点开搜索才弹键盘
    _searchOpen ? _searchFocus.requestFocus() : _searchFocus.unfocus();
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = v);
    });
  }

  // ---- 筛选谓词(模型 × 时间 × 搜索,全 AND) ----

  bool _passTime(ResultImage r) {
    if (_daysFilter == 0) return true;
    final now = DateTime.now();
    // 「今天」按日历日;7/30 天按滚动窗口
    final cut = _daysFilter == 1
        ? DateTime(now.year, now.month, now.day)
        : now.subtract(Duration(days: _daysFilter));
    return r.createdAt >= cut.millisecondsSinceEpoch;
  }

  bool _passModel(ResultImage r, Map<String, GallerySearchMeta> byId) {
    final want = _modelFilter;
    if (want == null) return true;
    return (byId[r.id]?.model ?? '') == want;
  }

  bool _passQuery(
    ResultImage r,
    Map<String, GallerySearchMeta> byId,
    List<String> terms,
  ) {
    if (terms.isEmpty) return true;
    final meta = byId[r.id];
    return meta != null && searchMatch(meta.text, terms);
  }

  /// 单选弹层(模型/时间共用):选项 = (文案, 值, 计数);值用单元素 record
  /// 包一层再 pop,可空的 T(全部=null)才与「取消」区分得开。
  Future<void> _pickFilter<T>({
    required String title,
    required List<(String, T, int?)> options,
    required T current,
    required ValueChanged<T> onPick,
  }) async {
    final scheme = context.scheme;
    // 弹层关闭后焦点会回落到搜索框(它一直在树里),不先收就会顺带弹出键盘
    _searchFocus.unfocus();
    final picked = await showModalBottomSheet<(T,)>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: context.texts.titleMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              for (final (label, value, count) in options)
                ListTile(
                  dense: true,
                  onTap: () => Navigator.pop(ctx, (value,)),
                  title: Text(label, style: context.texts.bodyMedium),
                  trailing: value == current
                      ? Icon(Icons.check, size: 18, color: scheme.primary)
                      : (count == null
                            ? null
                            : Text(
                                '$count',
                                style: mono(
                                  context,
                                  size: 12,
                                  color: scheme.outline,
                                ),
                              )),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onPick(picked.$1);
  }

  void _pickModelFilter(
    List<ResultImage> results,
    Map<String, GallerySearchMeta> byId,
  ) {
    // 模型清单按整库统计(不按筛选后,免得选中一个后其余选项全消失)
    final counts = <String, int>{};
    for (final r in results) {
      counts.update(byId[r.id]?.model ?? '', (v) => v + 1, ifAbsent: () => 1);
    }
    final models = [
      for (final k in counts.keys)
        if (k.isNotEmpty) k,
    ]..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    _pickFilter<String?>(
      title: '按模型筛选',
      current: _modelFilter,
      options: [
        ('全部', null, null),
        for (final m in models) (m, m, counts[m]),
        if ((counts[''] ?? 0) > 0) ('未知', '', counts['']),
      ],
      onPick: (v) => setState(() => _modelFilter = v),
    );
  }

  void _pickTimeFilter() {
    _pickFilter<int>(
      title: '按时间筛选',
      current: _daysFilter,
      options: const [
        ('全部', 0, null),
        ('今天', 1, null),
        ('近 7 天', 7, null),
        ('近 30 天', 30, null),
      ],
      onPick: (v) => setState(() => _daysFilter = v),
    );
  }

  Widget _chip(
    ColorScheme scheme, {
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final fg = active ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Material(
      color: active ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 7, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: context.texts.bodySmall!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 18, color: fg),
            ],
          ),
        ),
      ),
    );
  }

  /// 天分段段头:日期 + 张数;多选态尾部整段全选/取消。
  Widget _dayHeader(
    ColorScheme scheme,
    int dayKey,
    List<ResultImage> items,
    DateTime now,
  ) {
    final ids = [for (final r in items) r.id];
    final allOn = ids.every(_picked.contains);
    return Padding(
      // 跟着网格一起往里收 4:段头文字要和其下第一张图的左边缘对齐
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
      child: Row(
        children: [
          Text(
            galleryDayLabel(dayKey, now),
            style: context.texts.titleSmall!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            '${items.length} 张',
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (_selecting)
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: _saving
                  ? null
                  : () => setState(
                      () =>
                          allOn ? _picked.removeAll(ids) : _picked.addAll(ids),
                    ),
              child: Text(allOn ? '取消' : '全选'),
            ),
        ],
      ),
    );
  }

  void _enterSelect([String? pick]) {
    setState(() {
      _selecting = true;
      if (pick != null) _picked.add(pick);
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _picked.clear();
    });
  }

  void _toggle(String id) {
    setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id));
  }

  void _toggleAll(List<ResultImage> results) {
    setState(() {
      if (_picked.length == results.length) {
        _picked.clear();
      } else {
        _picked
          ..clear()
          ..addAll([for (final r in results) r.id]);
      }
    });
  }

  /// 批量保存:按默认保存设置逐张处理后存相册;逐张计数,
  /// 中途关闭弹层即中止(已存的保留)。
  /// [album] 非空 = 存进该自定义相册(gal 会按需创建 `Pictures/<album>/`)。
  /// [only] 非空 = 只存这些(长按菜单的单张保存借道同一条管线,
  /// 权限申请、保存设置、失败计数一条都不用重写)。
  Future<void> _downloadPicked({String? album, Set<String>? only}) async {
    final want = only ?? _picked;
    final items = [
      for (final r in ref.read(galleryProvider).results)
        if (want.contains(r.id)) r,
    ];
    if (items.isEmpty) return;
    // 写自建相册**以外**的相册要额外权限位,按目标申请
    final toAlbum = album != null;
    final ok =
        await Gal.hasAccess(toAlbum: toAlbum) ||
        await Gal.requestAccess(toAlbum: toAlbum);
    if (!mounted) return;
    if (!ok) {
      hintSnack(context, '未获相册权限', icon: Icons.error_outline);
      return;
    }
    final settings = await ref.read(saveSettingsProvider.future);
    if (!mounted) return;
    final store = ref.read(appStoresProvider).gallery;
    setState(() {
      _saving = true;
      _saveDone = 0;
      _saveTotal = items.length;
    });
    var saved = 0, failed = 0;
    for (final r in items) {
      if (!mounted) return; // 弹层已关:中止剩余
      try {
        final bytes = r.bytes ?? await store.readImage(r.id);
        if (bytes == null) {
          failed++;
        } else {
          final out = await processForSave(bytes, settings);
          await Gal.putImageBytes(out, name: 'plana_${r.seed}', album: album);
          saved++;
        }
      } catch (_) {
        failed++;
      }
      if (mounted) setState(() => _saveDone = saved + failed);
    }
    // 存成过才记进"最近用过"(全失败的名字记下来只会碍事)
    if (album != null && saved > 0) {
      await ref
          .read(saveSettingsProvider.notifier)
          .patch((s) => s.withAlbumUsed(album));
    }
    if (!mounted) return;
    setState(() => _saving = false);
    final where = album == null ? '相册' : '「$album」';
    hintSnack(
      context,
      failed == 0 ? '已保存 $saved 张到$where' : '保存 $saved 张到$where,失败 $failed 张',
      icon: failed == 0 ? Icons.check_circle_outline : Icons.error_outline,
    );
  }

  /// 保存到自定义相册:先问名字,再走同一条保存管线。
  Future<void> _downloadToAlbum() async {
    final settings = await ref.read(saveSettingsProvider.future);
    if (!mounted) return;
    final name = await showAlbumNameSheet(
      context,
      recent: settings.recentAlbums,
      count: _picked.length,
    );
    if (name == null || !mounted) return;
    await _downloadPicked(album: name);
  }

  /// 长按缩略图:就地弹出该张的操作菜单。
  ///
  /// 菜单锚在手指按下的位置,不用底部弹层 —— 从底下升起的那种会盖住下半屏,
  /// 正好挡掉刚长按的那张图,选项落在哪张上就说不清了。
  ///
  /// 删除排最后并单独隔一条线:菜单是在手指底下弹出来的,排第一位等于把
  /// 不可撤销的那项塞到最容易误落的地方。
  Future<void> _thumbMenu(String id, Offset at) async {
    Haptics.medium();
    final scheme = context.scheme;
    final box = Overlay.of(context).context.findRenderObject() as RenderBox;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & box.size),
      items: [
        const PopupMenuItem(
          value: 'import',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.input, size: 20),
            title: Text('导入'),
          ),
        ),
        const PopupMenuItem(
          value: 'save',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.download, size: 20),
            title: Text('保存'),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, size: 20, color: scheme.error),
            title: Text('删除', style: TextStyle(color: scheme.error)),
          ),
        ),
      ],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case 'import':
        await _importOne(id);
      case 'save':
        await _downloadPicked(only: {id});
      case 'delete':
        await _deleteOne(id);
    }
  }

  /// 导入:这张送进导入面板(解析内嵌元数据 / 用作参考),与画布侧栏同一个面板。
  ///
  /// 先关网格弹层再推面板 —— 面板是整页的,压在弹层上会留一层退不掉的夹心:
  /// 从面板返回时人会以为回到了画布,实际还在弹层里。
  Future<void> _importOne(String id) async {
    final r = ref
        .read(galleryProvider)
        .results
        .where((e) => e.id == id)
        .firstOrNull;
    if (r == null) return;
    final bytes =
        r.bytes ?? await ref.read(appStoresProvider).gallery.readImage(id);
    if (!mounted) return;
    if (bytes == null) {
      hintSnack(context, '图片尚未就绪', icon: Icons.hourglass_empty);
      return;
    }
    final nav = Navigator.of(context);
    nav.pop();
    unawaited(
      nav.push(
        sharedAxisRoute(
          ImportImagePanel(
            bytes: bytes,
            fileName: 'plana_${r.seed}.png',
            displayName: 'plana_${r.seed}',
          ),
        ),
      ),
    );
  }

  /// 单张删除(长按菜单里那项)。底部那条批量删除要先进多选,只想扔一张时太绕;
  /// 但删掉就找不回来,所以照样过一道确认。
  Future<void> _deleteOne(String id) async {
    if (!await confirmDialog(
      context,
      title: '删除这张作品?',
      message: '原图、缩略图与参数快照一并删除,不可撤销。',
      confirmLabel: '删除',
    )) {
      return;
    }
    if (!mounted) return;
    ref.read(galleryProvider.notifier).deleteResults([id]);
    if (ref.read(galleryProvider).results.isEmpty) {
      Navigator.of(context).pop(); // 删空了,弹层没得看
      return;
    }
    hintSnack(context, '已删除', icon: Icons.delete_outline);
  }

  Future<void> _deletePicked() async {
    final ids = _picked.toList();
    if (ids.isEmpty) return;
    final scheme = context.scheme;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('删除 ${ids.length} 张作品?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    ref.read(galleryProvider.notifier).deleteResults(ids);
    _exitSelect();
    if (ref.read(galleryProvider).results.isEmpty) {
      Navigator.of(context).pop(); // 删空了,弹层没得看
    }
    hintSnack(context, '已删除 ${ids.length} 张', icon: Icons.delete_outline);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(galleryProvider);
    final results = state.results;
    final search = ref.watch(gallerySearchProvider);

    // 筛选管线(先廉价的时间,再查表)
    final terms = searchTerms(_query);
    final filtered = <ResultImage>[
      for (final r in results)
        if (_passTime(r) &&
            _passModel(r, search.byId) &&
            _passQuery(r, search.byId, terms))
          r,
    ];
    final filtering =
        _query.isNotEmpty || _modelFilter != null || _daysFilter != 0;

    // 弹层开着期间条目可能被裁剪/删除/筛掉,勾选集随之收敛 ——
    // 批量操作永远只作用于当前可见集合,不留筛选外的"隐形勾选"
    _picked.removeWhere((id) => !filtered.any((r) => r.id == id));

    // 按天分段:列表天然新→旧,键的首现序即段序
    final byDay = <int, List<ResultImage>>{};
    for (final r in filtered) {
      byDay.putIfAbsent(galleryDayKey(r.createdAt), () => []).add(r);
    }
    final now = DateTime.now();

    final scheme = context.scheme;
    final h = MediaQuery.of(context).size.height * 0.82;
    final canAct = _picked.isNotEmpty && !_saving;

    return PopScope(
      // 多选态下系统返回/侧滑先退多选,不关弹层 —— 勾了十几张再手滑退出,
      // 重新勾一遍的代价比多按一次返回大得多。非多选态照常放行,
      // 好让预测式返回该怎么演就怎么演。
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _exitSelect();
      },
      child: SizedBox(
        height: h,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
              child: SizedBox(
                height: 36,
                child: _selecting
                    ? Row(
                        children: [
                          Text(
                            '已选 ${_picked.length} 张',
                            style: context.texts.titleMedium!.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => _toggleAll(filtered),
                            child: Text(
                              _picked.length == filtered.length &&
                                      filtered.isNotEmpty
                                  ? '全不选'
                                  : '全选',
                            ),
                          ),
                          TextButton(
                            onPressed: _saving ? null : _exitSelect,
                            child: const Text('完成'),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Text(
                            '全部作品',
                            style: context.texts.titleMedium!.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            filtering
                                ? '${filtered.length}/${results.length} 张'
                                : '${results.length} 张',
                            style: context.texts.bodySmall!.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: _toggleSearch,
                            visualDensity: VisualDensity.compact,
                            tooltip: '搜索提示词标签',
                            icon: Icon(
                              Icons.search,
                              size: 21,
                              color: _searchOpen
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                          TextButton(
                            onPressed: () => _enterSelect(),
                            child: const Text('多选'),
                          ),
                        ],
                      ),
              ),
            ),
            // 搜索框(点放大镜展开;关闭即清词)
            ExpandBody(
              expanded: _searchOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  style: context.texts.bodyMedium,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索提示词标签…',
                    prefixIcon: const Icon(Icons.search, size: 19),
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 17),
                            onPressed: () {
                              _searchCtrl.clear();
                              _onSearchChanged('');
                            },
                          ),
                    filled: true,
                    fillColor: scheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            // 筛选 chips + 检索索引回填进度
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  _chip(
                    scheme,
                    label: _modelFilter == null
                        ? '模型'
                        : (_modelFilter!.isEmpty ? '未知' : _modelFilter!),
                    active: _modelFilter != null,
                    onTap: () => _pickModelFilter(results, search.byId),
                  ),
                  const SizedBox(width: 8),
                  _chip(
                    scheme,
                    label: switch (_daysFilter) {
                      1 => '今天',
                      7 => '近 7 天',
                      30 => '近 30 天',
                      _ => '时间',
                    },
                    active: _daysFilter != 0,
                    onTap: _pickTimeFilter,
                  ),
                  if (search.building) ...[
                    const Spacer(),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '索引 ${search.done}/${search.total}',
                      style: context.texts.bodySmall!.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            filtering ? Icons.search_off : Icons.image_outlined,
                            size: 40,
                            color: scheme.outline,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            filtering ? '没有符合条件的作品' : '图库是空的',
                            style: context.texts.bodyMedium!.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : CustomScrollView(
                      slivers: [
                        for (final e in byDay.entries) ...[
                          SliverToBoxAdapter(
                            child: _dayHeader(scheme, e.key, e.value, now),
                          ),
                          // 缩略图本体还各带 5(描边 2.5 + 让位 2.5)的内缩,
                          // 所以图与图之间实际留白 = 这里的 spacing + 10。
                          // 收到 6 之后是 16,省下的宽度全给图。
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                            sliver: SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    mainAxisSpacing: 6,
                                    crossAxisSpacing: 6,
                                  ),
                              delegate: SliverChildBuilderDelegate((_, i) {
                                final r = e.value[i];
                                return _GridThumb(
                                  result: r,
                                  selected:
                                      !_selecting && r.id == state.selectedId,
                                  picked: _selecting && _picked.contains(r.id),
                                  selecting: _selecting,
                                  onTap: () {
                                    if (_selecting) {
                                      _toggle(r.id);
                                    } else {
                                      ref
                                          .read(galleryProvider.notifier)
                                          .select(r.id);
                                      Navigator.of(context).pop();
                                    }
                                  },
                                  onLongPress: _selecting
                                      ? null
                                      : (at) => _thumbMenu(r.id, at),
                                );
                              }, childCount: e.value.length),
                            ),
                          ),
                        ],
                        const SliverToBoxAdapter(child: SizedBox(height: 10)),
                      ],
                    ),
            ),
            // 多选操作栏:进出多选随高度动画滑入滑出
            AnimatedSize(
              duration: Motion.medium,
              curve: Motion.emphasized,
              child: !_selecting
                  ? const SizedBox(width: double.infinity)
                  : SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: canAct
                                        ? () => _downloadPicked()
                                        : null,
                                    icon: const Icon(Icons.download, size: 19),
                                    label: Text(
                                      _saving
                                          ? '保存中 $_saveDone/$_saveTotal'
                                          : '保存 (${_picked.length})',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: scheme.errorContainer,
                                      foregroundColor: scheme.onErrorContainer,
                                    ),
                                    onPressed: canAct ? _deletePicked : null,
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 19,
                                    ),
                                    label: Text('删除 (${_picked.length})'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // 独占一行:三颗横排在窄屏 + 大字号下会挤成省略号,
                            // 且这一颗要多一步选相册,与上面两颗的即时性不同级。
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: canAct ? _downloadToAlbum : null,
                                icon: const Icon(
                                  Icons.photo_album_outlined,
                                  size: 19,
                                ),
                                label: const Text('保存到自定义相册'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridThumb extends StatelessWidget {
  const _GridThumb({
    required this.result,
    required this.selected,
    required this.picked,
    required this.selecting,
    required this.onTap,
    this.onLongPress,
  });

  final ResultImage result;

  /// 普通模式:是否为画布当前选中项(主题色描边)。
  final bool selected;

  /// 多选模式:是否已勾选(主题色描边 + 勾选圆标)。
  final bool picked;
  final bool selecting;
  final VoidCallback onTap;

  /// 长按:带上手指的全局坐标,菜单要锚在按下去的地方。
  final void Function(Offset at)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final ring = selecting ? picked : selected;
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: onLongPress == null
          ? null
          : (d) => onLongPress!(d.globalPosition),
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: ring ? scheme.primary : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2.5),
          child: LayoutBuilder(
            builder: (_, c) => Stack(
              children: [
                ResultThumb(
                  result: result,
                  width: c.maxWidth,
                  height: c.maxWidth,
                  radius: 10,
                ),
                // 多选模式左上角换勾选圆标(角标让位)
                if (selecting)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: picked
                            ? scheme.primary
                            : Colors.black.withValues(alpha: .35),
                        border: picked
                            ? null
                            : Border.all(
                                color: Colors.white.withValues(alpha: .85),
                                width: 1.5,
                              ),
                      ),
                      child: picked
                          ? Icon(Icons.check, size: 15, color: scheme.onPrimary)
                          : null,
                    ),
                  )
                else if (result.badge != ResultBadge.none)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: ResultBadgeChip(badge: result.badge),
                  ),
                // 右下角生成时刻(日期由段头承担,段内标时刻才是增量信息)
                if (galleryTimeBadge(result.createdAt) case final String t
                    when t.isNotEmpty)
                  Positioned(
                    right: 5,
                    bottom: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .45),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        t,
                        style: mono(context, size: 9, weight: FontWeight.w600)
                            .copyWith(
                              color: Colors.white.withValues(alpha: .92),
                              height: 1,
                            ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
