import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/theme/app_theme.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart';
import '../generate/widgets/common.dart' show InfoNote, hintSnack;
import '../generate/widgets/lora_card.dart' show LoraThumb, LoraTypeBadge;
import 'lora_providers.dart';
import 'lora_upload_sheet.dart';

/// LoRA 管理器(anima / krea 出图渠道,结构对齐 web LoraManagerModal):
/// 我的(我下载过的 + 我上传的,🗑=移出;无人拥有的 web 条目由后端回收)
/// 公共库(机房里的公开条目,⭐=加入/移出我的库,按人气排序)
/// 在线搜索(Civitai 代理,ℹ=详情 ⬇=机房直拉下载,滚到底自动翻页)
/// 整卡点选 → 底栏「确认挂载」写回创作页(上限 [kMaxActiveLoras] 个)。
///
/// 全程只看**一个**底模([_base],进页时从当前模型定死):Anima 与 Krea2 的
/// 权重互不通用,列表、在线搜索、下载、上传都带着它 —— 混着列只会让人挂上
/// 一个静默无效的 LoRA。
class LoraManagerPage extends ConsumerStatefulWidget {
  const LoraManagerPage({super.key});

  @override
  ConsumerState<LoraManagerPage> createState() => _LoraManagerPageState();
}

const _kEdge = 16.0;

/// 上传入口的高度。空闲态是按钮、传输态是进度条,两者必须等高,
/// 否则一开传整个列表会往下跳一格。
const _kUploadBarHeight = 42.0;
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

  /// 本页认哪个底模的库。进页时定死:模型只能在创作页换,本页开着时不会变,
  /// 而中途改基准会让已选中的条目跨库串到确认挂载里去。
  late final String _base = ref.read(loraBaseProvider);

  String _search = '';
  final _searchCtl = TextEditingController();
  final Set<String> _selected = {};

  // 我的/公共库共用一份全集(/api/lora/list),常驻在 installedLorasProvider,
  // 管理器重开不重拉;下面这些只是本页的瞬时 UI 态。
  String? _busyName; // favorite/unfavorite 进行中的条目

  String _commCat = 'all';

  // 上传自己的 LoRA:0~100 = 本机→server 的百分比,null = 没在传。
  // 传输跑在本页而不是上传面板里,面板关掉、切 tab 都不打断。
  int? _uploadPct;

  /// server→机房的推送轮询,按 LR 编号一条一个(重进本页会给自己那些
  /// 还在推的条目重新接上)。
  final _pushTimers = <String, Timer>{};

  // 在线搜索
  final _onlineScroll = ScrollController();
  List<CivitaiLoraInfo> _onlineItems = [];
  String? _onlineCursor;
  bool _loadingOnline = false;
  bool _onlineLoadedOnce = false;
  String _onlineCat = 'all';

  /// 「二次元」开关,与左边的分类**可叠加**:分类是本地按推断出的 type 筛,
  /// 这个是服务端去 Civitai 侧按 tag=anime 筛,两者作用在不同环节。
  /// 对 krea 尤其必要 —— k2 是写实向底模,不筛的话默认列表里几乎翻不到二次元的。
  bool _onlineAnimeOnly = false;

  /// 当前这批在线结果对应的关键词(可能落后于输入框:切走时改过词)。
  String _onlineQuery = '';

  /// 每次新搜索自增,在途的旧请求回来时按它作废(不覆盖新结果)。
  int _searchSeq = 0;

  /// 「没铺满一屏就继续翻」的连翻计数,防分类过滤把整批滤空时无限翻页。
  int _autoPages = 0;

  /// 上一次搜索失败的原因:列表空时要说清是「搜不通」还是「真没有」。
  String? _onlineError;
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
      // 切到在线页:没搜过、或搜索框在别的页被改过 → 重搜(省无谓请求,但不留旧词的结果)
      if (_tab.index == 2 &&
          (!_onlineLoadedOnce || _onlineQuery != _search.trim())) {
        _searchDebounce?.cancel();
        _runSearch(reset: true);
      }
    });
    _onlineScroll.addListener(() {
      if (_tab.index != 2 || _loadingOnline || _onlineCursor == null) return;
      if (_onlineScroll.position.extentAfter < 400) {
        _autoPages = 0; // 用户自己滚到底,连翻计数重新起算
        _runSearch(reset: false);
      }
    });
    // 全集不在这儿拉:provider 常驻,首次 watch 才发请求,之后重开直接命中。
    // 但常驻也意味着重开时不会再触发 ref.listen —— 手上这份已有的值要自己看一眼
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _resumeWatch(ref.read(installedLorasProvider(_base)).value ?? const []);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    for (final t in _pushTimers.values) {
      t.cancel();
    }
    _searchCtl.dispose();
    _onlineScroll.dispose();
    _tab.dispose();
    super.dispose();
  }

  Future<String?> _sid() async =>
      (await ref.read(botSessionProvider.future))?.sessionId;

  Future<void> _loadInstalled() =>
      ref.read(installedLorasProvider(_base).notifier).reload();

  /// 在线搜索。[reset] = 换词/换分类的新搜索(丢弃在途请求),否则是续下一页。
  ///
  /// 新搜索**不能**因为「有请求在跑」就被丢掉 —— Civitai 代理一趟好几秒,
  /// 边打字边翻页时几乎次次撞上,那正是「搜了没反应」的由来。
  /// 改成发号作废:每次新搜索 [_searchSeq] 自增,旧请求回来时对不上号就整个忽略。
  Future<void> _runSearch({required bool reset}) async {
    if (!reset && (_loadingOnline || _onlineCursor == null)) return;
    final seq = ++_searchSeq;
    // 游标属于产出它的那次搜索:续页仍用当批的词,不跟着输入框半路改口
    final query = reset ? _search.trim() : _onlineQuery;
    final cat = _onlineCat;
    // 与 cat 同样先取快照:这趟要 await 好几秒,期间用户完全可能再点开关
    final animeOnly = _onlineAnimeOnly;
    final cursor = reset ? null : _onlineCursor;
    if (reset) _autoPages = 0;
    setState(() {
      _loadingOnline = true;
      _onlineError = null;
    });
    try {
      final r = await ref
          .read(backendClientProvider)
          .searchLoras(
            query: query,
            cursor: cursor,
            // 具体分类是客户端过滤,用大页一次出一整批;「全部」小页更快(对齐 web)
            limit: cat == 'all' ? 24 : 60,
            base: _base, // Civitai 那边按 baseModel=Anima / Krea 2 过滤
            tag: animeOnly ? 'anime' : '',
          );
      if (!mounted || seq != _searchSeq) return; // 已被更新的搜索取代
      final next = r.nextCursor;
      setState(() {
        _onlineLoadedOnce = true;
        _onlineQuery = query;
        _onlineItems = reset ? r.items : [..._onlineItems, ...r.items];
        _onlineCursor = (next == null || next.isEmpty) ? null : next;
        _loadingOnline = false;
      });
      _autoPageIfShort();
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _loadingOnline = false;
        _onlineError = '$e';
      });
      hintSnack(context, '$e', icon: Icons.cloud_off);
    }
  }

  /// 一批结果被分类过滤后可能只剩几条,列表压根没到能滚的长度 ——
  /// 滚动监听永远不触发,自动翻页就断在这儿。所以每批落地后补一次判断:
  /// 还没铺满一屏且有下一页游标就接着翻(最多连翻 [_kMaxAutoPages] 次,
  /// 再多就交给列表底部的「加载更多」,免得整批滤空时无限打 Civitai)。
  static const _kMaxAutoPages = 5;

  void _autoPageIfShort() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _tab.index != 2 ||
          _loadingOnline ||
          _onlineCursor == null ||
          _autoPages >= _kMaxAutoPages ||
          _onlineScroll.positions.length != 1) {
        return;
      }
      if (_onlineScroll.position.extentAfter < 400) {
        _autoPages++;
        _runSearch(reset: false);
      }
    });
  }

  void _onSearchChanged(String v) {
    setState(() => _search = v);
    if (_tab.index != 2) return; // 本地两页是纯前端过滤,切回在线页时再重搜
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _startSearch();
    });
  }

  /// 键盘「搜索」键 / 清空按钮 / 换分类:不等防抖,立刻发。
  void _startSearch() {
    _searchDebounce?.cancel();
    _runSearch(reset: true);
  }

  void _toggleSelect(LoraCardInfo item) {
    if (_selected.contains(item.name)) {
      setState(() => _selected.remove(item.name));
      return;
    }
    // 还没推进机房的条目挂上去出图必炸,拦在这儿(对齐 web)
    if (!item.ready) {
      hintSnack(context, item.pushing ? '还在推送到机房,就绪后可挂载' : '该 LoRA 未就绪,暂不能挂载');
      return;
    }
    if (_selected.length >= kMaxActiveLoras) {
      hintSnack(context, '最多同时挂载 $kMaxActiveLoras 个 LoRA');
      return;
    }
    setState(() => _selected.add(item.name));
  }

  /// 上传就绪 / 去重命中后替用户选上。已达上限就不硬塞(返回 false,由调用方改口)。
  bool _autoSelect(String name) {
    if (_selected.contains(name)) return true;
    if (_selected.length >= kMaxActiveLoras) return false;
    setState(() => _selected.add(name));
    return true;
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
      });
      final loras = ref.read(installedLorasProvider(_base).notifier);
      if (r.deleted) {
        loras.dropByName(item.name);
      } else {
        loras.patch(
          item.name,
          favorited: false,
          favoriteCount: r.favoriteCount,
        );
      }
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
      ref
          .read(installedLorasProvider(_base).notifier)
          .patch(item.name, favorited: true, favoriteCount: r.favoriteCount);
      hintSnack(context, '已加入我的库', icon: Icons.check);
    } catch (e) {
      if (mounted) hintSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busyName = null);
    }
  }

  // ---- 上传自己的 LoRA ----

  /// 选文件填表 → 传给 server(它校验完只登记就返回,推进机房是它的后台活)。
  /// 所以传完不算完:拿到编号后接着 [_watchPush] 盯推送,synced 才是能挂载。
  Future<void> _startUpload() async {
    final draft = await showLoraUploadSheet(context);
    if (draft == null || !mounted) return;
    final sid = await _sid();
    if (!mounted) return;
    if (sid == null) {
      hintSnack(context, '需要 Bot 授权登录');
      return;
    }
    setState(() => _uploadPct = 0);
    try {
      final r = await ref
          .read(backendClientProvider)
          .uploadLora(
            sessionId: sid,
            filePath: draft.path,
            fileName: draft.fileName,
            fileSize: draft.size,
            displayName: draft.displayName,
            triggerGroups: draft.triggerGroups,
            type: draft.type,
            public: draft.public,
            base: _base, // 决定文件落 Volume 的哪个子目录 → 之后能被哪个渠道挂载
            onProgress: (p) {
              // 每块都回调(几百兆能有几千次),整数百分比不变就不重建
              final v = (p * 100).clamp(0, 100).round();
              if (!mounted || v == _uploadPct) return;
              setState(() => _uploadPct = v);
            },
          );
      if (!mounted) return;
      if (!r.ok) {
        hintSnack(context, r.message.isEmpty ? '上传失败' : r.message);
        return;
      }
      await _loadInstalled();
      final id = r.lrId;
      if (!mounted || id == null) return;
      if (r.dedup) {
        // 同一个文件机房里已经有了,后端没重复存,直接给收藏了
        final ok = _autoSelect(id);
        hintSnack(
          context,
          r.message.isEmpty ? '该文件已在库中,已为你收藏' : r.message,
          icon: ok ? Icons.check : Icons.info_outline,
        );
      } else {
        hintSnack(context, '已接收,正在推送到机房…', icon: Icons.cloud_upload_outlined);
        _watchPush(id);
      }
    } catch (e) {
      if (mounted) hintSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _uploadPct = null);
    }
  }

  /// 盯 server→机房的推送(3s 一问,对齐 web)。就绪→刷新列表并替用户选上;
  /// 失败→刷新列表,卡片上会出现重试按钮。
  void _watchPush(String lrId) {
    if (_pushTimers.containsKey(lrId)) return;
    _pushTimers[lrId] = Timer.periodic(const Duration(seconds: 3), (t) async {
      final ({bool ok, String status, String? error}) st;
      try {
        st = await ref.read(backendClientProvider).loraUploadStatus(lrId);
      } catch (_) {
        return; // 网络抖一下不算数,下一轮再问
      }
      if (!mounted || st.status == 'uploading' || st.status == 'pending') {
        return;
      }
      t.cancel();
      _pushTimers.remove(lrId);
      await _loadInstalled();
      if (!mounted) return;
      if (st.status == 'synced') {
        final ok = _autoSelect(lrId);
        hintSnack(
          context,
          ok ? '$lrId 已就绪并选中,点「确认挂载」生效' : '$lrId 已就绪',
          icon: Icons.check,
        );
      } else if (st.status == 'failed') {
        hintSnack(
          context,
          '推送机房失败:${st.error ?? '未知原因'},可在卡片上重试',
          icon: Icons.cloud_off,
        );
      }
    });
  }

  /// 轮询只活在本页:重进管理器时,把自己那些还在推送的条目重新接上。
  void _resumeWatch(List<LoraCardInfo> all) {
    for (final x in all) {
      if (x.pushing && x.isOwner) _watchPush(x.name);
    }
  }

  /// 推送失败重来(服务端留着收到的那份临时文件,不用重传)。
  Future<void> _retryPush(LoraCardInfo item) async {
    setState(() => _busyName = item.name);
    try {
      final sid = await _sid();
      if (sid == null) return;
      final r = await ref
          .read(backendClientProvider)
          .retryLoraUpload(sessionId: sid, lrId: item.name);
      if (!mounted) return;
      hintSnack(
        context,
        r.message.isEmpty ? (r.ok ? '已重新开始推送' : '重试失败') : r.message,
        icon: r.ok ? Icons.cloud_upload_outlined : Icons.error_outline,
      );
      if (!r.ok) return;
      await _loadInstalled();
      if (!mounted) return;
      _watchPush(item.name);
    } catch (e) {
      if (mounted) hintSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busyName = null);
    }
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
          .installLora(sessionId: sid, versionId: item.versionId, base: _base);
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
    final all =
        ref.read(installedLorasProvider(_base)).value ?? const <LoraCardInfo>[];
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
            hasTe: c.hasTe,
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

  /// 未授权(provider 抛 need-bot)给人话,其余原样透出。
  static String? _errText(Object? e) {
    if (e == null) return null;
    if (e is StateError && e.message == 'need-bot') return '需要 Bot 授权登录';
    return '$e';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    // 刷新后可能多出「还在推送」的自家条目(比如另一端传的),接着盯
    ref.listen(installedLorasProvider(_base), (_, next) {
      final items = next.value;
      if (items != null) _resumeWatch(items);
    });
    final async = ref.watch(installedLorasProvider(_base));
    final all = async.value ?? const <LoraCardInfo>[];
    final mine = [
      for (final x in all)
        if (x.favorited) x,
    ];
    // 私有条目(自己上传、只有自己拉得到)不进公共库,只留在「我的」
    final community = [
      for (final x in all)
        if (!x.isPrivate) x,
    ];
    // 有旧值就照常渲染,刷新只在标题栏转圈;首拉才整页 loading。
    // 刷新失败同理不掀桌 —— 手上这份还能用来挂载。
    final firstLoad = async.isLoading && !async.hasValue;
    final error = async.hasValue ? null : _errText(async.error);

    return Scaffold(
      appBar: AppBar(
        title: const Text('LoRA 管理器'),
        actions: [
          if (async.isLoading)
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
              controller: _searchCtl,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) {
                if (_tab.index == 2) _startSearch();
              },
              decoration: InputDecoration(
                isDense: true,
                hintText: _tab.index == 2
                    ? '搜索 Civitai 上的 ${_base == 'krea' ? 'Krea 2' : 'Anima'} LoRA…'
                    : '搜索名称或触发词…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: '清空',
                        onPressed: () {
                          _searchCtl.clear();
                          setState(() => _search = '');
                          if (_tab.index == 2) _startSearch();
                        },
                      ),
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
            child: _segTabs(scheme, mine.length, community.length),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _mineTab(mine, firstLoad: firstLoad, error: error),
                _communityTab(community, firstLoad: firstLoad, error: error),
                _onlineTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _bottomBar(scheme, ready: async.hasValue),
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
  Widget _mineTab(
    List<LoraCardInfo> mine, {
    required bool firstLoad,
    required String? error,
  }) {
    final items = [
      for (final x in mine)
        if (_matchSearch(x)) x,
    ];
    if (error != null) return _errorBody(error);
    if (firstLoad) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_kEdge, 4, _kEdge, 8),
          child: _uploadEntry(),
        ),
        Expanded(
          child: items.isEmpty
              ? _emptyBody(
                  icon: Icons.smartphone,
                  text: mine.isEmpty ? '我的库还是空的' : '没有匹配的 LoRA',
                  action: mine.isEmpty
                      ? TextButton(
                          onPressed: () => _tab.animateTo(2),
                          child: const Text('去在线下载 →'),
                        )
                      : null,
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(_kEdge, 0, _kEdge, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final x = items[i];
                    return _LibraryCard(
                      item: x,
                      selected: _selected.contains(x.name),
                      onTap: () => _toggleSelect(x),
                      action: _busyName == x.name
                          ? const _BusyIcon()
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (x.syncStatus == 'failed' && x.isOwner)
                                  IconButton(
                                    tooltip: '重试推送到机房',
                                    icon: const Icon(Icons.refresh),
                                    onPressed: () => _retryPush(x),
                                  ),
                                IconButton(
                                  tooltip: '删除(移出我的库)',
                                  icon: Icon(
                                    Icons.delete_outline,
                                    color: context.scheme.error,
                                  ),
                                  onPressed: () => _unfavorite(x),
                                ),
                              ],
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 上传入口。传输期间整条按钮变成进度条(从左往右填),不另占位置 ——
  /// 传输跑在本页,面板关掉、切 tab 都还看得见它走到哪了。
  Widget _uploadEntry() {
    final scheme = context.scheme;
    final pct = _uploadPct;
    if (pct == null) {
      return OutlinedButton.icon(
        onPressed: _startUpload,
        icon: const Icon(Icons.upload_file, size: 18),
        label: const Text('上传我的 LoRA(.safetensors)'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(_kUploadBarHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
    // 100% 之后还要等服务端算完整份文件的 SHA 才回执,那段没进度可报:
    // 条填满不动,换个转圈告诉用户还没完
    final verifying = pct >= 100;
    return Container(
      height: _kUploadBarHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: .5)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: (pct / 100).clamp(0.0, 1.0),
            heightFactor: 1,
            child: ColoredBox(color: scheme.primary.withValues(alpha: .22)),
          ),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (verifying)
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  )
                else
                  Icon(Icons.upload_file, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  verifying ? '校验中…' : '上传中 $pct%',
                  style: context.texts.labelLarge!.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- 公共库 ----
  Widget _communityTab(
    List<LoraCardInfo> all, {
    required bool firstLoad,
    required String? error,
  }) {
    if (error != null) return _errorBody(error);
    if (firstLoad) return const Center(child: CircularProgressIndicator());
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
                      onTap: () => _toggleSelect(x),
                      action: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 与在线页同位的 ℹ:那边看 Civitai 的卡片,这边看机房里
                          // 这一份(编号 / 谁传的 / 推送状态 / CLIP 能不能调)
                          IconButton(
                            tooltip: '详情',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.info_outline),
                            color: context.scheme.onSurfaceVariant,
                            onPressed: () => _showLibraryDetail(x),
                          ),
                          if (_busyName == x.name)
                            const _BusyIcon()
                          else
                            IconButton(
                              tooltip: x.favorited ? '移出我的库' : '加入我的库',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                x.favorited ? Icons.star : Icons.star_border,
                                color: x.favorited
                                    ? context.scheme.primary
                                    : context.scheme.onSurfaceVariant,
                              ),
                              onPressed: () =>
                                  x.favorited ? _unfavorite(x) : _favorite(x),
                            ),
                        ],
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
        // 「二次元」排在分类前面:它是服务端按 tag 筛(决定拉回什么),分类是本地
        // 按 type 筛(在拉回的结果里挑),两者可叠加。用带勾的 FilterChip 而不是
        // 第五个分类 chip —— 后者会被读成「和角色/画风四选一」。
        _catChips(
          _onlineCat,
          (k) {
            if (k == _onlineCat) return;
            setState(() {
              _onlineCat = k;
              _onlineItems = [];
              _onlineCursor = null;
            });
            _startSearch();
          },
          leading: FilterChip(
            label: const Text('二次元'),
            selected: _onlineAnimeOnly,
            visualDensity: VisualDensity.compact,
            tooltip: _onlineAnimeOnly ? '点击取消,显示全部内容' : '只看二次元',
            // 服务端过滤,不像分类那样能在已有结果里筛 —— 必须重发请求
            onSelected: (v) {
              setState(() {
                _onlineAnimeOnly = v;
                _onlineItems = [];
                _onlineCursor = null;
              });
              _startSearch();
            },
          ),
        ),
        Expanded(
          child: !_onlineLoadedOnce && _onlineError == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty && !_loadingOnline && _onlineCursor == null
              ? (_onlineError != null
                    // 搜不通和真没有,得能一眼分清(以前都写「没有结果」)
                    ? _emptyBody(
                        icon: Icons.cloud_off,
                        text: _onlineError!,
                        action: TextButton(
                          onPressed: _startSearch,
                          child: const Text('重试'),
                        ),
                      )
                    : _emptyBody(icon: Icons.public, text: '没有结果'))
              : ListView.separated(
                  controller: _onlineScroll,
                  padding: const EdgeInsets.fromLTRB(_kEdge, 4, _kEdge, 16),
                  itemCount: items.length + (_onlineFooter == null ? 0 : 1),
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => i >= items.length
                      ? _onlineFooter!
                      : _onlineCardRow(items[i]),
                ),
        ),
      ],
    );
  }

  /// 列表尾:加载中转圈;还有下一页给个手点入口(连翻到上限、或列表短到滚不动时的退路);
  /// 翻完了就不占位。
  Widget? get _onlineFooter {
    if (_loadingOnline) {
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
    if (_onlineCursor == null) return null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: TextButton(
          onPressed: () {
            _autoPages = 0;
            _runSearch(reset: false);
          },
          child: const Text('加载更多'),
        ),
      ),
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
          // 与公共库同位的 ℹ。整卡点开也是详情,但那不显眼 —— 公共库那边有按钮、
          // 这边只能靠猜,同一页两套规矩。
          IconButton(
            tooltip: '详情',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.info_outline),
            color: scheme.onSurfaceVariant,
            onPressed: () => _showDetail(x),
          ),
          if (busy)
            const _BusyIcon()
          else if (done)
            IconButton(
              tooltip: '已在我的库',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.check, color: scheme.primary),
              onPressed: null,
            )
          else
            IconButton(
              tooltip: x.installed ? '加入我的库(库内已有,不重复下载)' : '下载到我的库(机房直拉)',
              visualDensity: VisualDensity.compact,
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
                          // 先发车、立刻重建,再等结果:_download 的头两行是同步的
                          // (置 _downloadingVid),所以这时 setSheet 就能把按钮切成
                          // 「下载中…」。只在 await 之后刷新的话,整个下载期间弹层
                          // 纹丝不动 —— 用户看到的就是「点了没反应」,退出去才发现
                          // 列表那行在转圈。
                          onPressed: done || busy
                              ? null
                              : () async {
                                  final task = _download(x);
                                  setSheet(() {});
                                  await task;
                                  if (sheetCtx.mounted) setSheet(() {});
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

  /// 详情页的一格「标签 + 值」。在线卡与库内卡两张详情共用同一套版式。
  Widget _metaCell(String label, String value) {
    final scheme = context.scheme;
    return Container(
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
  }

  Widget _metaGridOf(List<Widget> cells) => GridView.count(
    crossAxisCount: 2,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    childAspectRatio: 3.4,
    mainAxisSpacing: 6,
    crossAxisSpacing: 6,
    children: cells,
  );

  Widget _metaGrid(CivitaiLoraInfo x) {
    return _metaGridOf([
      _metaCell('作者', x.creator.isEmpty ? '—' : x.creator),
      _metaCell('推荐权重', '${x.recommendedWeight}'),
      _metaCell('下载数', '${x.downloadCount}'),
      _metaCell('大小', x.sizeMb != null ? '${x.sizeMb} MB' : '—'),
      _metaCell('基础模型', x.baseModel.isEmpty ? '—' : x.baseModel),
      _metaCell('文件', x.fileName.isEmpty ? '—' : x.fileName),
    ]);
  }

  /// 库内条目详情(公共库的 ℹ)。在线那张详情看的是 Civitai 的卡片,这张看的是
  /// **机房里这一份**:LR 编号、谁传的、推送状态、CLIP 能不能调 —— 都是卡片行上
  /// 放不下、但决定「挂上去会怎样」的信息。
  void _showLibraryDetail(LoraCardInfo opened) {
    final scheme = context.scheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .62,
        maxChildSize: .92,
        // StatefulBuilder 在外、Consumer 在内:收藏结果靠 provider 通知(Consumer),
        // 但「正在请求」是本页的 _busyName、provider 不会动 —— 那段得靠 setSheet
        // 自己重建,否则整个请求期间弹层纹丝不动。
        builder: (_, scroll) => StatefulBuilder(
          builder: (_, setSheet) => Consumer(
            builder: (_, ref2, _) {
              // 收藏关系会被弹层自己底下那颗按钮改掉,所以每次都从库里取最新那条;
              // 条目被回收(最后一个收藏者移出)后回落到打开时的快照,按钮那边会收场。
              final all =
                  ref2.watch(installedLorasProvider(_base)).value ??
                  const <LoraCardInfo>[];
              final x =
                  all.where((e) => e.name == opened.name).firstOrNull ?? opened;
              final busy = _busyName == x.name;
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
                                    x.displayName,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.texts.titleSmall!.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      LoraTypeBadge(x.type),
                                      if (x.isPrivate)
                                        Text(
                                          '私有',
                                          style: context.texts.labelSmall!
                                              .copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      if (!x.ready)
                                        Text(
                                          switch (x.syncStatus) {
                                            'uploading' => '推送中',
                                            'failed' => '推送失败',
                                            _ => '未就绪',
                                          },
                                          style: context.texts.labelSmall!
                                              .copyWith(
                                                color: x.syncStatus == 'failed'
                                                    ? scheme.error
                                                    : scheme.tertiary,
                                              ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _metaGridOf([
                          // 编号就是进生成载荷的那个键,排第一
                          _metaCell('编号', x.name),
                          _metaCell('推荐权重', '${x.recommendedWeight}'),
                          _metaCell('收藏人数', '${x.favoriteCount}'),
                          _metaCell('使用次数', '${x.usageCount}'),
                          _metaCell(
                            '大小',
                            x.sizeMb != null ? '${x.sizeMb} MB' : '—',
                          ),
                          _metaCell(
                            '来源',
                            x.addedBy == 'bot'
                                ? '官方'
                                : (x.isOwner ? '我上传的' : '用户上传'),
                          ),
                          // 没训文本编码器的,CLIP 强度调了不会有任何变化 ——
                          // 挂之前就该知道,不然会对着没反应的滑杆调半天
                          _metaCell('CLIP 强度', switch (x.hasTe) {
                            false => '不可调(无 TE)',
                            true => '可调',
                            _ => '未探测',
                          }),
                        ]),
                        if (x.syncError != null) ...[
                          const SizedBox(height: 12),
                          InfoNote(
                            '推送失败:${x.syncError}',
                            icon: Icons.cloud_off,
                            color: scheme.error,
                          ),
                        ],
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
                      ],
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
                      child: Row(
                        children: [
                          if (x.sourceUrl.isNotEmpty)
                            TextButton.icon(
                              onPressed: () => launchUrl(
                                Uri.parse(x.sourceUrl),
                                mode: LaunchMode.externalApplication,
                              ),
                              icon: const Icon(Icons.open_in_new, size: 16),
                              label: const Text('查看来源'),
                            ),
                          const Spacer(),
                          FilledButton.icon(
                            // 同在线详情那颗:先发车再重建(_favorite / _unfavorite
                            // 的头一行同步置 _busyName),否则请求期间按钮毫无反应
                            onPressed: busy
                                ? null
                                : () async {
                                    final task = x.favorited
                                        ? _unfavorite(x)
                                        : _favorite(x);
                                    setSheet(() {});
                                    await task;
                                    if (!sheetCtx.mounted) return;
                                    setSheet(() {});
                                    // 移出后这条被机房回收了(最后一个拥有者),
                                    // 详情已经没有对应实体,别留在原地
                                    final gone =
                                        !(ref2
                                                    .read(
                                                      installedLorasProvider(
                                                        _base,
                                                      ),
                                                    )
                                                    .value ??
                                                const <LoraCardInfo>[])
                                            .any((e) => e.name == x.name);
                                    if (gone) Navigator.pop(sheetCtx);
                                  },
                            icon: busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    x.favorited
                                        ? Icons.star
                                        : Icons.star_border,
                                    size: 18,
                                  ),
                            label: Text(x.favorited ? '移出我的库' : '加入我的库'),
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
      ),
    );
  }

  // ---- 公共小件 ----
  /// 分类筛选行。[leading] 是排在分类前面的额外筛选件(在线页的「二次元」),
  /// 跟着一起横向滚 —— 钉在右端的话窄屏上会把分类挤没。
  Widget _catChips(
    String current,
    ValueChanged<String> onPick, {
    Widget? leading,
  }) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _kEdge),
        children: [
          if (leading != null) ...[
            Center(child: leading),
            // 竖线分组:左边这个是服务端筛(决定拉回什么),右边是本地筛(在拉回的
            // 结果里挑)。不隔开会被读成同一组五选一。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: SizedBox(
                  height: 18,
                  child: VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: context.scheme.outlineVariant,
                  ),
                ),
              ),
            ),
          ],
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

  Widget _bottomBar(ColorScheme scheme, {required bool ready}) {
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
              onPressed: ready ? _confirm : null,
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
    final label = context.texts.labelSmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    Widget stat(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: scheme.onSurfaceVariant),
        const SizedBox(width: 2),
        Text(text, style: label),
      ],
    );

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
                // 徽标最多能同时挂到六七个(私有 + 推送状态都算),窄屏放不下,
                // 用 Wrap 让它折行而不是压出溢出条
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    LoraTypeBadge(item.type),
                    Text('w${item.recommendedWeight}', style: label),
                    if (item.triggerWords.isNotEmpty)
                      stat(Icons.key, '${item.triggerWords.length}'),
                    if (item.favoriteCount > 0)
                      stat(Icons.people_outline, '${item.favoriteCount}'),
                    if (item.isPrivate) stat(Icons.lock_outline, '私有'),
                    if (showOfficial && item.addedBy == 'bot')
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
                    if (!item.ready)
                      Text(
                        switch (item.syncStatus) {
                          'uploading' => '推送中',
                          'failed' => '推送失败',
                          _ => '未就绪',
                        },
                        style: context.texts.labelSmall!.copyWith(
                          color: item.syncStatus == 'failed'
                              ? scheme.error
                              : scheme.tertiary,
                        ),
                      ),
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
