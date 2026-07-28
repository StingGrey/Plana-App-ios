import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../store/app_stores.dart';
import '../theme/app_theme.dart';
import 'selection_bar.dart';

/// 上次选过的相册 id,存 `settings.json`。
///
/// 全应用只有这一个选择器(导入图片 / 图生图 / Vibe / 角色参考…… 都走它),
/// 所以记在这里 = 所有入口共享:在哪个相册挑过,下次从哪个相册开始。
///
/// 不进 [PrefsStore.migrateKeys] —— 那份名单是给「原本存在 secure storage、
/// 需要搬家」的老设置项用的,新键从来没在那儿待过,登记只会白读一次。
const _kAlbumKey = 'picker_album';

/// 选择结果:选中的资产,或用户改走系统文件浏览器兜底。
class GalleryPickOutcome {
  const GalleryPickOutcome.assets(this.assets) : useFileBrowser = false;

  const GalleryPickOutcome.fileBrowser()
    : assets = const [],
      useFileBrowser = true;

  final List<AssetEntity> assets;
  final bool useFileBrowser;
}

/// 应用内图库选择器:photo_manager 直读系统媒体库,全部相册/全部图片可达。
/// 系统照片选择器只放行固定几个分类且不看 app 权限,只能自建绕开。
class GalleryPickerPage extends ConsumerStatefulWidget {
  const GalleryPickerPage({super.key, required this.multiple});

  final bool multiple;

  @override
  ConsumerState<GalleryPickerPage> createState() => _GalleryPickerPageState();
}

class _GalleryPickerPageState extends ConsumerState<GalleryPickerPage>
    with WidgetsBindingObserver {
  static const _pageSize = 120;

  PermissionState? _perm; // null = 请求中
  List<AssetPathEntity> _albums = const [];
  AssetPathEntity? _album;
  final _assets = <AssetEntity>[];
  int _page = 0;
  bool _exhausted = false;
  bool _loadingMore = false;

  final _sel = <AssetEntity>[];
  final _selIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置/部分照片授权面板回来时重查权限与列表。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _perm?.hasAccess != true) {
      _init();
    }
  }

  Future<void> _init() async {
    final ps = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _perm = ps);
    // 用同步的 get(内存态):多一个 await 就要多一道 mounted 检查,不值当。
    // 相册没了(被删/权限收窄)时 keepId 匹配不上,_loadAlbums 自己回落第一个。
    if (ps.hasAccess) {
      await _loadAlbums(keepId: ref.read(prefsStoreProvider).get(_kAlbumKey));
    }
  }

  Future<void> _loadAlbums({String? keepId}) async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (!mounted) return;
    AssetPathEntity? cur;
    if (keepId != null) {
      for (final a in albums) {
        if (a.id == keepId) {
          cur = a;
          break;
        }
      }
    }
    cur ??= albums.isEmpty ? null : albums.first;
    setState(() => _albums = albums);
    await _selectAlbum(cur);
  }

  Future<void> _selectAlbum(AssetPathEntity? album) async {
    setState(() {
      _album = album;
      _assets.clear();
      _page = 0;
      _exhausted = album == null;
      _loadingMore = false;
    });
    if (album != null) await _loadMore();
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loadingMore || _exhausted) return;
    _loadingMore = true;
    try {
      final batch = await album.getAssetListPaged(page: _page, size: _pageSize);
      if (!mounted || album != _album) return;
      setState(() {
        _assets.addAll(batch);
        _page++;
        if (batch.length < _pageSize) _exhausted = true;
      });
    } finally {
      _loadingMore = false;
    }
  }

  void _toggle(AssetEntity a) {
    setState(() {
      if (_selIds.remove(a.id)) {
        _sel.removeWhere((e) => e.id == a.id);
      } else {
        _selIds.add(a.id);
        _sel.add(a);
      }
    });
  }

  void _clearSel() => setState(() {
    _sel.clear();
    _selIds.clear();
  });

  String _albumLabel(AssetPathEntity a) =>
      a.isAll ? '全部图片' : (a.name.isEmpty ? '图库' : a.name);

  Future<void> _switchAlbum() async {
    final picked = await showModalBottomSheet<AssetPathEntity>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final a in _albums)
              ListTile(
                dense: true,
                selected: a.id == _album?.id,
                title: Text(
                  _albumLabel(a),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: FutureBuilder<int>(
                  future: a.assetCountAsync,
                  builder: (context, snap) => Text(
                    snap.hasData ? '${snap.data}' : '',
                    style: mono(context, color: context.scheme.outline),
                  ),
                ),
                onTap: () => Navigator.of(sheet).pop(a),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked.id == _album?.id) return;
    // 只在用户**主动选**时记(不记回落的默认相册)——记的是「选择过的」。
    await ref
        .read(prefsStoreProvider)
        .write(key: _kAlbumKey, value: picked.id);
    if (!mounted) return;
    await _selectAlbum(picked);
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final perm = _perm;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        // 加载态与相册名同一套字样,列表到位时标题不变粗、不跳动
        title: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _album != null && _albums.length > 1 ? _switchAlbum : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _album == null ? '选择图片' : _albumLabel(_album!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.titleMedium,
                  ),
                ),
                if (_album != null) const Icon(Icons.arrow_drop_down, size: 22),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '从文件选',
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: () => Navigator.of(
              context,
            ).pop(const GalleryPickOutcome.fileBrowser()),
          ),
        ],
      ),
      // 权限请求中(perm == null)与列表加载中都走骨架网格,避免空白/跳变
      body: perm != null && !perm.hasAccess
          ? _NoAccessView(onRetry: _init)
          : Column(
              children: [
                if (perm == PermissionState.limited)
                  _LimitedBar(
                    onManage: () async {
                      await PhotoManager.presentLimited(
                        type: RequestType.image,
                      );
                      if (mounted) await _loadAlbums(keepId: _album?.id);
                    },
                  ),
                Expanded(
                  child: _assets.isEmpty
                      ? (_exhausted
                            ? Center(
                                child: Text(
                                  '没有图片',
                                  style: context.texts.bodyMedium!.copyWith(
                                    color: scheme.outline,
                                  ),
                                ),
                              )
                            : const _SkeletonGrid())
                      : NotificationListener<ScrollNotification>(
                          onNotification: (n) {
                            if (n.metrics.pixels >
                                n.metrics.maxScrollExtent - 900) {
                              _loadMore();
                            }
                            return false;
                          },
                          child: GridView.builder(
                            padding: const EdgeInsets.all(2),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 2,
                                  crossAxisSpacing: 2,
                                ),
                            itemCount: _assets.length,
                            itemBuilder: (context, i) => _cell(_assets[i]),
                          ),
                        ),
                ),
              ],
            ),
      // 多选才有底栏(单选点一下就返回)。版式与各管理器的多选底栏同一套,
      // 只是这里没有批量操作,第一层整行省掉 —— 见 SelectionBar。
      bottomNavigationBar: widget.multiple && perm?.hasAccess == true
          ? SelectionBar(
              visible: _sel.isNotEmpty,
              onClear: _sel.isEmpty ? null : _clearSel,
              primary: FilledButton.icon(
                onPressed: _sel.isEmpty
                    ? null
                    : () => Navigator.of(
                        context,
                      ).pop(GalleryPickOutcome.assets(List.of(_sel))),
                style: selectionPrimaryStyle(),
                icon: const Icon(Icons.check, size: 18),
                label: Text('确定 (${_sel.length})'),
              ),
            )
          : null,
    );
  }

  Widget _cell(AssetEntity a) {
    final scheme = context.scheme;
    final selected = _selIds.contains(a.id);
    return GestureDetector(
      onTap: () => widget.multiple
          ? _toggle(a)
          : Navigator.of(context).pop(GalleryPickOutcome.assets([a])),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 缩略图解码前的底色(与骨架同色,进场不闪白)
          ColoredBox(color: scheme.surfaceContainerHigh),
          AssetEntityImage(
            a,
            isOriginal: false,
            thumbnailSize: const ThumbnailSize.square(300),
            fit: BoxFit.cover,
            errorBuilder: (context, _, _) => ColoredBox(
              color: scheme.surfaceContainerHigh,
              child: Icon(Icons.broken_image_outlined, color: scheme.outline),
            ),
          ),
          if (widget.multiple) ...[
            if (selected)
              Container(
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .16),
                  border: Border.all(color: scheme.primary, width: 3),
                ),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: selected
                  ? Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 15,
                        color: scheme.onPrimary,
                      ),
                    )
                  : Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: .18),
                        border: Border.all(color: Colors.white, width: 1.6),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 加载骨架:与实际网格同版式的呼吸色块(权限请求中/相册首载/切相册时)。
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) => _Pulse(
    child: GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: 24,
      itemBuilder: (context, _) =>
          ColoredBox(color: context.scheme.surfaceContainerHigh),
    ),
  );
}

/// 呼吸式明暗包装(与统计页骨架同节奏)。
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(
      begin: .45,
      end: 1,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
    child: widget.child,
  );
}

/// Android 14「部分照片」授权提示条。
class _LimitedBar extends StatelessWidget {
  const _LimitedBar({required this.onManage});

  final Future<void> Function() onManage;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 6, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '仅可访问部分图片',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ),
          TextButton(onPressed: onManage, child: const Text('调整')),
        ],
      ),
    );
  }
}

/// 无权限视图:去系统设置授权后回来自动刷新,也可手动重查。
class _NoAccessView extends StatelessWidget {
  const _NoAccessView({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, size: 40, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            '需要相册访问权限',
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: PhotoManager.openSetting,
            child: const Text('去设置'),
          ),
          TextButton(onPressed: onRetry, child: const Text('重新检查')),
        ],
      ),
    );
  }
}
