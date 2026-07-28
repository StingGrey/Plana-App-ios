import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/theme/app_theme.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../generate/widgets/lora_card.dart' show LoraThumb, LoraTypeBadge;

/// LoRA 管理器(anima 出图渠道专用,结构对齐 web LoraManagerModal):
/// 我的(我下载过的,🗑=移出;无人拥有的 web 条目由后端回收)
/// 公共库(机房全集,⭐=加入/移出我的库,按人气排序)
/// 在线搜索(Civitai 代理,ℹ=详情 ⬇=机房直拉下载,滚到底自动翻页)
/// 整卡点选 → 底栏「确认挂载」写回创作页(上限 5 个)。
class LoraManagerPage extends ConsumerStatefulWidget {
  const LoraManagerPage({super.key});

  @override
  ConsumerState<LoraManagerPage> createState() => _LoraManagerPageState();
}

const _kEdge = 16.0;
const _cats = <(String, String)>[
  ('all', '全部'),
  ('character', '角色'),
  ('style', '画风'),
  ('concept', '概念'),
];

class _LoraManagerPageState extends ConsumerState<LoraManagerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);
  int _lastTabIndex = 0;

  String _search = '';
  final Set<String> _selected = {};

  // 我的/公共库共用一份全集(/api/lora/list)
  List<LoraCardInfo>? _installed;
  bool _loadingLocal = false;
  String? _loadError;
  String? _busyName; // favorite/unfavorite 进行中的条目

  String _commCat = 'all';

  // 在线搜索
  final _onlineScroll = ScrollController();
  List<CivitaiLoraInfo> _onlineItems = [];
  String? _onlineCursor;
  bool _loadingOnline = false;
  bool _onlineLoadedOnce = false;
  String _onlineCat = 'all';
  int? _downloadingVid;
  final Set<int> _downloadedVids = {};
  final Map<String, int> _vidByLrId = {}; // 移出我的库时回退在线「已下载」✓
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _selected.addAll(ref.read(generateProvider).loras.map((l) => l.name));
    _tab.addListener(() {
      if (_tab.index == _lastTabIndex) return;
      _lastTabIndex = _tab.index;
      setState(() {});
      // 首次切到在线页才发起搜索(省无谓请求)
      if (_tab.index == 2 && !_onlineLoadedOnce && !_loadingOnline) {
        _runSearch(reset: true);
      }
    });
    _onlineScroll.addListener(() {
      if (_tab.index != 2 || _loadingOnline || _onlineCursor == null) return;
      if (_onlineScroll.position.extentAfter < 400) _runSearch(reset: false);
    });
    _loadInstalled();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _onlineScroll.dispose();
    _tab.dispose();
    super.dispose();
  }

  Future<String?> _sid() async =>
      (await ref.read(botSessionProvider.future))?.sessionId;

  Future<void> _loadInstalled() async {
    setState(() {
      _loadingLocal = true;
      _loadError = null;
    });
    try {
      final sid = await _sid();
      if (sid == null) {
        setState(() => _loadError = '需要 Bot 授权登录');
        return;
      }
      final items = await ref.read(backendClientProvider).listLoras(sid);
      if (!mounted) return;
      setState(() => _installed = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '$e');
    } finally {
      if (mounted) setState(() => _loadingLocal = false);
    }
  }

  Future<void> _runSearch({required bool reset}) async {
    if (_loadingOnline) return;
    setState(() => _loadingOnline = true);
    try {
      final r = await ref
          .read(backendClientProvider)
          .searchLoras(
            query: _search.trim(),
            cursor: reset ? null : _onlineCursor,
            // 具体分类是客户端过滤,用大页一次出一整批;「全部」小页更快(对齐 web)
            limit: _onlineCat == 'all' ? 24 : 60,
          );
      if (!mounted) return;
      setState(() {
        _onlineLoadedOnce = true;
        _onlineItems = reset ? r.items : [..._onlineItems, ...r.items];
        _onlineCursor = r.nextCursor;
      });
    } catch (e) {
      if (mounted) hintSnack(context, '$e', icon: Icons.cloud_off);
    } finally {
      if (mounted) setState(() => _loadingOnline = false);
    }
  }

  void _onSearchChanged(String v) {
    setState(() => _search = v);
    if (_tab.index != 2) return; // 本地两页是纯前端过滤
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _runSearch(reset: true);
    });
  }

  void _toggleSelect(String name) {
    setState(() {
      if (!_selected.remove(name)) {
        if (_selected.length >= kMaxActiveLoras) {
          hintSnack(context, '最多同时挂载 $kMaxActiveLoras 个 LoRA');
          return;
        }
        _selected.add(name);
      }
    });
  }

  // 我的库移除 / 公共库星标共用:移出我的库,必要时后端回收
  Future<void> _unfavorite(LoraCardInfo item) async {
    setState(() => _busyName = item.name);
    try {
      final sid = await _sid();
      if (sid == null) return;
      final r = await ref
          .read(backendClientProvider)
          .unfavoriteLora(sessionId: sid, lrId: item.name);
      if (!mounted) return;
      if (!r.ok) {
        hintSnack(context, r.message.isEmpty ? '移除失败' : r.message);
        return;
      }
      setState(() {
        _selected.remove(item.name);
        final vid = _vidByLrId.remove(item.name);
        if (vid != null) _downloadedVids.remove(vid);
        if (r.deleted) {
          _installed?.removeWhere((x) => x.name == item.name);
        } else {
          _patchInstalled(
            item.name,
            favorited: false,
            favoriteCount: r.favoriteCount,
          );
        }
      });
      hintSnack(context, '已移出我的库', icon: Icons.check);
    } catch (e) {
      if (mounted) hintSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busyName = null);
    }
  }

  Future<void> _favorite(LoraCardInfo item) async {
    setState(() => _busyName = item.name);
    try {
      final sid = await _sid();
      if (sid == null) return;
      final r = await ref
          .read(backendClientProvider)
          .favoriteLora(sessionId: sid, lrId: item.name);
      if (!mounted) return;
      if (!r.ok) {
        hintSnack(context, r.message.isEmpty ? '加入失败' : r.message);
        return;
      }
      setState(() {
        _patchInstalled(
          item.name,
          favorited: true,
          favoriteCount: r.favoriteCount,
        );
      });
      hintSnack(context, '已加入我的库', icon: Icons.check);
    } catch (e) {
      if (mounted) hintSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busyName = null);
    }
  }

  /// 收藏关系就地更新(全集列表元素不可变,重建该条)。
  void _patchInstalled(String name, {bool? favorited, int? favoriteCount}) {
    final list = _installed;
    if (list == null) return;
    final i = list.indexWhere((x) => x.name == name);
    if (i < 0) return;
    final o = list[i];
    list[i] = LoraCardInfo(
      name: o.name,
      displayName: o.displayName,
      type: o.type,
      triggerWords: o.triggerWords,
      recommendedWeight: o.recommendedWeight,
      previewUrl: o.previewUrl,
      sourceUrl: o.sourceUrl,
      sizeMb: o.sizeMb,
      syncStatus: o.syncStatus,
      usageCount: o.usageCount,
      addedBy: o.addedBy,
      favorited: favorited ?? o.favorited,
      favoriteCount: favoriteCount ?? o.favoriteCount,
    );
  }

  Future<void> _download(CivitaiLoraInfo item) async {
    if (_downloadingVid != null) return;
    setState(() => _downloadingVid = item.versionId);
    try {
      final sid = await _sid();
      if (!mounted) return;
      if (sid == null) {
        hintSnack(context, '需要 Bot 授权登录');
        return;
      }
      final r = await ref
          .read(backendClientProvider)
          .installLora(sessionId: sid, versionId: item.versionId);
      if (!mounted) return;
      if (!r.ok && r.lrId == null) {
        hintSnack(context, r.message.isEmpty ? '下载失败' : r.message);
        return;
      }
      setState(() {
        _downloadedVids.add(item.versionId);
        final id = r.lrId;
        if (id != null) _vidByLrId[id] = item.versionId;
      });
      hintSnack(
        context,
        r.message.isEmpty ? '已加入我的库' : r.message,
        icon: Icons.check,
      );
      await _loadInstalled();
    } catch (e) {
      if (mounted) hintSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _downloadingVid = null);
    }
  }

  void _confirm() {
    final all = _installed ?? const <LoraCardInfo>[];
    final picked = [
      for (final c in all)
        if (_selected.contains(c.name))
          ActiveLora(
            name: c.name,
            displayName: c.displayName,
            weight: c.recommendedWeight,
            triggerWords: c.triggerWords,
            previewUrl: c.previewUrl,
            type: c.type,
          ),
    ];
    ref.read(generateProvider.notifier).applyLoraSelection(picked);
    Navigator.of(context).pop();
  }

  bool _matchSearch(LoraCardInfo x) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return true;
    return x.displayName.toLowerCase().contains(q) ||
        x.name.toLowerCase().contains(q) ||
        x.triggerWords.join(' ').toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final all = _installed ?? const <LoraCardInfo>[];
    final mine = [
      for (final x in all)
        if (x.favorited) x,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('LoRA 管理器'),
        actions: [
          if (_loadingLocal)
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
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: _loadInstalled,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(_kEdge, 6, _kEdge, 0),
            child: TextField(
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                isDense: true,
                hintText: _tab.index == 2
                    ? '搜索 Civitai 上的 Anima LoRA…'
                    : '搜索名称或触发词…',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(_kEdge, 8, _kEdge, 8),
            child: _segTabs(scheme, mine.length, all.length),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _mineTab(mine),
                _communityTab(all),
                _onlineTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _bottomBar(scheme),
    );
  }

  // ---- 分段 Tab(视觉对齐 Vibe/画风管理器,3 段) ----
  Widget _segTabs(ColorScheme scheme, int mineCount, int allCount) {
    return SizedBox(
      height: 42,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: AnimatedBuilder(
          animation: _tab.animation!,
          builder: (context, _) {
            final t = _tab.animation!.value.clamp(0.0, 2.0);
            return LayoutBuilder(
              builder: (context, c) {
                final segW = c.maxWidth / 3;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 3,
                      bottom: 3,
                      left: 3 + t * segW,
                      width: segW - 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          borderRadius: BorderRadius.circular(9),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .06),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        _segLabel(0, Icons.smartphone, '我的 · $mineCount', t),
                        _segLabel(1, Icons.dns_outlined, '公共库 · $allCount', t),
                        _segLabel(2, Icons.public, '在线搜索', t),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _segLabel(int index, IconData icon, String text, double t) {
    final scheme = context.scheme;
    final sel = (1 - (t - index).abs()).clamp(0.0, 1.0);
    final color = Color.lerp(scheme.onSurfaceVariant, scheme.onSurface, sel)!;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => _tab.animateTo(index),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 5),
              Text(
                text,
                style: context.texts.labelLarge!.copyWith(
                  color: color,
                  fontWeight: FontWeight.lerp(
                    FontWeight.w500,
                    FontWeight.w700,
                    sel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 我的 ----
  Widget _mineTab(List<LoraCardInfo> mine) {
    final items = [
      for (final x in mine)
        if (_matchSearch(x)) x,
    ];
    if (_loadError != null) return _errorBody(_loadError!);
    if (_loadingLocal && _installed == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return _emptyBody(
        icon: Icons.smartphone,
        text: mine.isEmpty ? '我的库还是空的' : '没有匹配的 LoRA',
        action: mine.isEmpty
            ? TextButton(
                onPressed: () => _tab.animateTo(2),
                child: const Text('去在线下载 →'),
              )
            : null,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(_kEdge, 4, _kEdge, 16),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final x = items[i];
        return _LibraryCard(
          item: x,
          selected: _selected.contains(x.name),
          onTap: () => _toggleSelect(x.name),
          action: _busyName == x.name
              ? const _BusyIcon()
              : IconButton(
                  tooltip: '删除(移出我的库)',
                  icon: Icon(
                    Icons.delete_outline,
                    color: context.scheme.error,
                  ),
                  onPressed: () => _unfavorite(x),
                ),
        );
      },
    );
  }

  // ---- 公共库 ----
  Widget _communityTab(List<LoraCardInfo> all) {
    if (_loadError != null) return _errorBody(_loadError!);
    if (_loadingLocal && _installed == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final items =
        [
            for (final x in all)
              if ((_commCat == 'all' || x.type == _commCat) && _matchSearch(x))
                x,
          ]
          // 人气(收藏人数)降序 → 使用次数降序(对齐 web)
          ..sort(
            (a, b) => b.favoriteCount != a.favoriteCount
                ? b.favoriteCount - a.favoriteCount
                : b.usageCount - a.usageCount,
          );
    return Column(
      children: [
        _catChips(_commCat, (k) => setState(() => _commCat = k)),
        Expanded(
          child: items.isEmpty
              ? _emptyBody(
                  icon: Icons.dns_outlined,
                  text: all.isEmpty ? '机房里还没有 LoRA' : '没有匹配的 LoRA',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(_kEdge, 4, _kEdge, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final x = items[i];
                    return _LibraryCard(
                      item: x,
                      selected: _selected.contains(x.name),
                      showOfficial: true,
                      onTap: () => _toggleSelect(x.name),
                      action: _busyName == x.name
                          ? const _BusyIcon()
                          : IconButton(
                              tooltip: x.favorited ? '移出我的库' : '加入我的库',
                              icon: Icon(
                                x.favorited ? Icons.star : Icons.star_border,
                                color: x.favorited
                                    ? context.scheme.primary
                                    : context.scheme.onSurfaceVariant,
                              ),
                              onPressed: () =>
                                  x.favorited ? _unfavorite(x) : _favorite(x),
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---- 在线搜索 ----
  Widget _onlineTab() {
    final items = [
      for (final x in _onlineItems)
        if (_onlineCat == 'all' || x.type == _onlineCat) x,
    ];
    return Column(
      children: [
        _catChips(_onlineCat, (k) {
          if (k == _onlineCat) return;
          setState(() {
            _onlineCat = k;
            _onlineItems = [];
            _onlineCursor = null;
          });
          _runSearch(reset: true);
        }),
        Expanded(
          child: !_onlineLoadedOnce && _loadingOnline
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty && !_loadingOnline
              ? _emptyBody(icon: Icons.public, text: '没有结果')
              : ListView.separated(
                  controller: _onlineScroll,
                  padding: const EdgeInsets.fromLTRB(_kEdge, 4, _kEdge, 16),
                  itemCount: items.length + (_loadingOnline ? 1 : 0),
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    if (i >= items.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    return _onlineCardRow(items[i]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _onlineCardRow(CivitaiLoraInfo x) {
    final scheme = context.scheme;
    final done = _downloadedVids.contains(x.versionId);
    final busy = _downloadingVid == x.versionId;
    return _CardShell(
      selected: false,
      onTap: () => _showDetail(x),
      child: Row(
        children: [
          LoraThumb(x.previewUrl, size: 46),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  x.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    LoraTypeBadge(x.type),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.download_outlined,
                      size: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        '${x.downloadCount}'
                        '${x.sizeMb != null ? ' · ${x.sizeMb!.toStringAsFixed(0)}MB' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (busy)
            const _BusyIcon()
          else if (done)
            IconButton(
              tooltip: '已在我的库',
              icon: Icon(Icons.check, color: scheme.primary),
              onPressed: null,
            )
          else
            IconButton(
              tooltip: x.installed ? '加入我的库(库内已有,不重复下载)' : '下载到我的库(机房直拉)',
              icon: Icon(Icons.download_outlined, color: scheme.primary),
              onPressed: () => _download(x),
            ),
        ],
      ),
    );
  }

  void _showDetail(CivitaiLoraInfo x) {
    final scheme = context.scheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .62,
        maxChildSize: .92,
        builder: (_, scroll) => StatefulBuilder(
          builder: (_, setSheet) {
            final done = _downloadedVids.contains(x.versionId);
            final busy = _downloadingVid == x.versionId;
            return Column(
              children: [
                Expanded(
                  child: ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                    children: [
                      Row(
                        children: [
                          LoraThumb(x.previewUrl, size: 52),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  x.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.titleSmall!.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    LoraTypeBadge(x.type),
                                    if (x.installed) ...[
                                      const SizedBox(width: 6),
                                      Text(
                                        '库内已有',
                                        style: context.texts.labelSmall!
                                            .copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _metaGrid(x),
                      const SizedBox(height: 14),
                      Text(
                        '触发词',
                        style: context.texts.labelMedium!.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (x.triggerWords.isEmpty)
                        Text(
                          '无',
                          style: context.texts.bodySmall!.copyWith(
                            color: scheme.outline,
                          ),
                        )
                      else
                        for (final t in x.triggerWords)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.key,
                                    size: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text(
                                      t,
                                      style: context.texts.bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      if (x.tags.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          '标签',
                          style: context.texts.labelMedium!.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final t in x.tags)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  t,
                                  style: context.texts.labelSmall!.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        '简介',
                        style: context.texts.labelMedium!.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        x.description.trim().isEmpty
                            ? '(无简介)'
                            : x.description.trim(),
                        style: context.texts.bodySmall!.copyWith(height: 1.5),
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse(x.civitaiUrl),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('在 Civitai 查看'),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: done || busy
                              ? null
                              : () async {
                                  await _download(x);
                                  setSheet(() {});
                                },
                          icon: Icon(
                            done ? Icons.check : Icons.download_outlined,
                            size: 18,
                          ),
                          label: Text(
                            busy
                                ? '下载中…'
                                : done
                                ? '已在我的库'
                                : '下载',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _metaGrid(CivitaiLoraInfo x) {
    final scheme = context.scheme;
    Widget cell(String label, String value) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.texts.labelSmall!.copyWith(color: scheme.outline),
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
    final cells = <Widget>[
      cell('作者', x.creator.isEmpty ? '—' : x.creator),
      cell('推荐权重', '${x.recommendedWeight}'),
      cell('下载数', '${x.downloadCount}'),
      cell('大小', x.sizeMb != null ? '${x.sizeMb} MB' : '—'),
      cell('基础模型', x.baseModel.isEmpty ? '—' : x.baseModel),
      cell('文件', x.fileName.isEmpty ? '—' : x.fileName),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 3.4,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      children: cells,
    );
  }

  // ---- 公共小件 ----
  Widget _catChips(String current, ValueChanged<String> onPick) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _kEdge),
        children: [
          for (final (key, label) in _cats)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: current == key,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => onPick(key),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyBody({
    required IconData icon,
    required String text,
    Widget? action,
  }) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: scheme.outlineVariant),
          const SizedBox(height: 10),
          Text(
            text,
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 4), action],
        ],
      ),
    );
  }

  Widget _errorBody(String message) {
    return _emptyBody(
      icon: Icons.cloud_off,
      text: message,
      action: TextButton(onPressed: _loadInstalled, child: const Text('重试')),
    );
  }

  Widget _bottomBar(ColorScheme scheme) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(_kEdge, 8, _kEdge, 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4)),
          ),
        ),
        child: Row(
          children: [
            TextButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => setState(_selected.clear),
              child: Text(
                '清空',
                style: TextStyle(
                  color: _selected.isEmpty ? null : scheme.error,
                ),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              // 全集没加载出来时确认会把已挂的误清空,禁掉
              onPressed: _installed == null ? null : _confirm,
              child: Text('确认挂载 (${_selected.length})'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 库卡片(我的/公共库共用):整卡点=选中挂载,右侧动作按 tab 注入。
class _LibraryCard extends StatelessWidget {
  const _LibraryCard({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.action,
    this.showOfficial = false,
  });

  final LoraCardInfo item;
  final bool selected;
  final VoidCallback onTap;
  final Widget action;
  final bool showOfficial;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return _CardShell(
      selected: selected,
      onTap: onTap,
      child: Row(
        children: [
          LoraThumb(item.previewUrl, size: 46),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                    color: selected ? scheme.primary : scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    LoraTypeBadge(item.type),
                    const SizedBox(width: 6),
                    Text(
                      'w${item.recommendedWeight}',
                      style: context.texts.labelSmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (item.triggerWords.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.key, size: 11, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 1),
                      Text(
                        '${item.triggerWords.length}',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (item.favoriteCount > 0) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.people_outline,
                        size: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 1),
                      Text(
                        '${item.favoriteCount}',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (showOfficial && item.addedBy == 'bot') ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          '官方',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ],
                    if (!item.ready) ...[
                      const SizedBox(width: 6),
                      Text(
                        '未就绪',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.tertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: .08)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: .35),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _BusyIcon extends StatelessWidget {
  const _BusyIcon();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
