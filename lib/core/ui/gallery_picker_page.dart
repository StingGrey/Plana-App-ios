import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../store/app_stores.dart';
import '../theme/app_theme.dart';
import '../util/log.dart';
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
  /// 每批取多少张。**别往大了调。**
  ///
  /// photo_manager 每把一行游标转成资产都要做一次 `File(path).exists()` 文件
  /// 系统 stat(`toAssetEntity` 的 `checkIfExists` 在插件里写死是 true,Dart 侧
  /// 关不掉)。普通机器上一次 stat 可以忽略,桥接文件系统上(鸿蒙 + 卓易通那类
  /// Android 兼容层)一次就是一趟跨运行时调用 —— 原来一批 120 张,进页要盯着
  /// 骨架空等七秒才出图。
  ///
  /// 取到刚好铺满一屏(3 列 × 10 行)即可,余量分批补,见 [_selectAlbum]。
  static const _pageSize = 30;

  /// 媒体库查询条件,本页所有查询共用一份。
  ///
  /// `ignoreSize: true` 是重点:photo_manager 默认往 WHERE 里塞
  /// `width > 0 AND height > 0 AND width BETWEEN ? AND ?`(高同理)。这几列在
  /// MediaStore 里没索引,提供方还得为没记尺寸的行现开文件算 —— 库一大就是整
  /// 表慢查询,媒体库是桥接实现时(鸿蒙 + 卓易通那类 Android 兼容层)更明显。
  /// 选图不看尺寸,去掉纯赚。
  static final _filter = FilterOptionGroup(
    imageOption: const FilterOption(
      sizeConstraint: SizeConstraint(ignoreSize: true),
    ),
    orders: const [OrderOption(type: OrderOptionType.createDate, asc: false)],
  );

  PermissionState? _perm; // null = 请求中
  AssetPathEntity? _album;
  final _assets = <AssetEntity>[];
  int _page = 0;
  bool _exhausted = false;
  bool _loadingMore = false;

  /// 全部相册:首次点标题切相册时才拉(为什么不在进页时拉,见
  /// [_openInitialAlbum])。失败不缓存,下次点还能重来。
  Future<List<AssetPathEntity>>? _albumsFuture;

  final _sel = <AssetEntity>[];
  final _selIds = <String>{};

  /// 媒体库变更通知的合并窗口。一次保存往往连发好几条(插入 + 缩略图 + 扫描),
  /// 逐条重拉既浪费也会让列表抖。
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PhotoManager.addChangeCallback(_onLibraryChanged);
    _init();
  }

  /// 开启系统媒体库变更通知。**必须等权限到手再开** —— 插件的 ContentObserver
  /// 在 onChange 里要反查 MediaStore 才能判断是新增还是修改,没有读权限那一步
  /// 查不动。原先跟 addChangeCallback 一起放在 initState,而权限是 _init() 里
  /// 异步申请的,那段窗口里发生的变更等于白丢。
  bool _notifyOn = false;

  void _ensureChangeNotify() {
    if (_notifyOn) return;
    _notifyOn = true;
    PhotoManager.startChangeNotify();
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    if (_notifyOn) PhotoManager.stopChangeNotify();
    PhotoManager.removeChangeCallback(_onLibraryChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onLibraryChanged(MethodCall _) {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), _reload);
  }

  /// 重拉当前相册。**补回原有批数**:直接重来只剩两批,用户要是已经翻下去了,
  /// 列表骤然变短会把滚动位置甩到底。
  Future<void> _reload() async {
    if (!mounted || _perm?.hasAccess != true) return;
    final pages = _page;
    await _openInitialAlbum(keepId: _album?.id);
    while (mounted && _page < pages && !_exhausted) {
      final before = _page;
      await _loadMore();
      if (_page == before) break; // 没推进就别空转
    }
  }

  /// 回到前台:没权限的重查权限(可能刚在系统设置里改过),有权限的重拉列表 ——
  /// 后台期间新增的图,变更通知未必送得到。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_perm?.hasAccess != true) {
      _init();
    } else {
      _reload();
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
    if (ps.hasAccess) _ensureChangeNotify();
    // 用同步的 get(内存态):多一个 await 就要多一道 mounted 检查,不值当。
    // 相册没了(被删/权限收窄)时取不到,_openInitialAlbum 自己回落全部图片。
    if (ps.hasAccess) {
      await _openInitialAlbum(
        keepId: ref.read(prefsStoreProvider).get(_kAlbumKey),
      );
    }
  }

  /// 进页只解析**这一次要打开的那个相册**,不枚举全部相册。
  ///
  /// 全量枚举(`getAssetPathList` 不带 `onlyAll`)在 Android 上要把媒体库整表
  /// 游标逐行走一遍按 bucket 分桶计数 —— 几千张图就是几千次逐行取值,进页直接
  /// 卡住几秒;媒体库是桥接实现时(鸿蒙 + 卓易通)一行一行更贵。这里退成两种
  /// 都只查一行 + count 的便宜路子,相册列表挪到 [_switchAlbum] 里按需拉。
  Future<void> _openInitialAlbum({String? keepId}) async {
    final all = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true, // 只要「全部图片」:一次 cursor.count,不逐行分桶
      filterOption: _filter,
    );
    var cur = all.isEmpty ? null : all.first;
    if (keepId != null && keepId != cur?.id) {
      // 上次挑的是别的相册:按 id 单取(只查一行 + count)。相册被删/权限
      // 收窄时取不到,回落「全部图片」—— 与旧的 keepId 匹配不上同样处理。
      try {
        cur = await AssetPathEntity.fromId(
          keepId,
          type: RequestType.image,
          filterOption: _filter,
        );
      } catch (e) {
        logd('[picker] 上次的相册取不到($keepId),回落全部图片: $e');
      }
    }
    if (!mounted) return;
    await _selectAlbum(cur);
  }

  /// 拉全部相册(整表分桶,慢),只在用户点开切相册面板时走一次。
  Future<List<AssetPathEntity>> _fetchAlbums() async {
    try {
      return await PhotoManager.getAssetPathList(
        type: RequestType.image,
        filterOption: _filter,
      );
    } catch (e) {
      _albumsFuture = null; // 失败不留在缓存里,下次点还能重试
      logd('[picker] 相册列表读取失败: $e');
      return const [];
    }
  }

  Future<void> _selectAlbum(AssetPathEntity? album) async {
    setState(() {
      _album = album;
      _assets.clear();
      _page = 0;
      _exhausted = album == null;
      _loadingMore = false;
    });
    if (album == null) return;
    await _loadMore(); // 首批:先把一屏喂出来,骨架尽早退场
    await _loadMore(); // 再补一批当滚动余量,免得一划就断档
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
    final albums = _albumsFuture ??= _fetchAlbums();
    final picked = await showModalBottomSheet<AssetPathEntity>(
      context: context,
      builder: (sheet) => SafeArea(
        child: FutureBuilder<List<AssetPathEntity>>(
          future: albums,
          builder: (context, snap) {
            final list = snap.data;
            if (list == null) {
              return const SizedBox(
                height: 96,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (list.isEmpty) {
              return ListTile(
                dense: true,
                enabled: false,
                title: Text('没有相册', style: context.texts.bodyMedium),
              );
            }
            // 逐条懒建:每行的张数都是一次媒体库查询,一次性建完整张列表
            // 会同时打出几十条查询,慢媒体库上面板会僵住。
            return ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (context, i) {
                final a = list[i];
                return ListTile(
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
                );
              },
            );
          },
        ),
      ),
    );
    if (picked == null || picked.id == _album?.id) return;
    // 只在用户**主动选**时记(不记回落的默认相册)——记的是「选择过的」。
    await ref.read(prefsStoreProvider).write(key: _kAlbumKey, value: picked.id);
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
          onTap: _album != null ? _switchAlbum : null,
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
                      if (!mounted) return;
                      _albumsFuture = null; // 授权范围变了,相册列表得重拉
                      await _openInitialAlbum(keepId: _album?.id);
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
                      // 下拉刷新是**兜底**:自动刷新依赖系统的 MediaStore 变更
                      // 广播,部分定制系统会限制或延迟投递,那时手动这一下是唯一
                      // 不依赖广播的路。
                      : RefreshIndicator(
                          onRefresh: _reload,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              if (n.metrics.pixels >
                                  n.metrics.maxScrollExtent - 900) {
                                _loadMore();
                              }
                              return false;
                            },
                            child: GridView.builder(
                              // 内容不满一屏时也要能下拉
                              physics: const AlwaysScrollableScrollPhysics(),
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
