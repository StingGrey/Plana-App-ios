import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/scroll_memory.dart';
import '../generate/generate_state.dart';
import '../generate/widgets/common.dart'
    show ExpandBody, confirmDialog, hintSnack, sharedAxisRoute;
import '../shell/shell_state.dart';
import 'public_tags.dart';
import 'tag_editor_page.dart';
import 'tag_library.dart';
import 'tag_models.dart';
import 'widgets/tag_sheets.dart';

/// 顶部各行统一的左右边距;行尾若是 IconButton,用 [_kIconEdge]
/// (减去按钮 8px 内衬)让图标视觉边与其他行对齐。
const _kEdge = 14.0;
const _kIconEdge = 6.0;

/// 网格分组:一个区头 + 该组条目(我的/收藏的/公共)。
typedef _Group = ({Widget header, List<TagEntry> items});

/// 网格卡片间距(骨架与真实网格共用,保证切换时不跳位)。
const _gap = 10.0;

/// 灵感页:web Tag 管理器的移动端形态(底部 tab 常驻页,非弹窗)。
/// 布局随 Vibe 管理器(搜索 + 我的/公共库分段 + 网格 + 底部操作条),
/// 分类切换走左侧抽屉(角色/画风/场景/其他;自定义分类未开放,不做)。
class InspirationPage extends ConsumerStatefulWidget {
  const InspirationPage({super.key});

  @override
  ConsumerState<InspirationPage> createState() => _InspirationPageState();
}

class _InspirationPageState extends ConsumerState<InspirationPage>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  TagCategory _cat = TagCategory.character;
  late final TabController _tab = TabController(length: 2, vsync: this);
  // 初始分类的记忆直接灌进 initialScrollOffset;换分类走 _switchCategory 落位。
  late final _mineScroll = ScrollController(
    initialScrollOffset: ScrollMemory.read(_scrollKey(_cat, false)) ?? 0,
  );
  late final _pubScroll = ScrollController(
    initialScrollOffset: ScrollMemory.read(_scrollKey(_cat, true)) ?? 0,
  );

  /// 每分类已选 id(我的/公共库两 scope 共用一套,对齐 web selectionMap)。
  final Map<TagCategory, Set<String>> _selected = {};

  String _search = '';

  /// 筛选:null=全部;[_kFavFilter]=收藏;其余为标签名。
  String? _filter;
  static const _kFavFilter = ' fav';

  /// 批量操作进行中(禁重入)。
  bool _busy = false;

  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    // 只在整数位变化时 setState(筛选行随 scope 显隐)。
    _tab.animation!.addListener(() {
      final i = _tab.animation!.value.round();
      if (i != _tabIndex && mounted) setState(() => _tabIndex = i);
    });
    _mineScroll.addListener(() => _saveScroll(_mineScroll, false));
    _pubScroll.addListener(() => _saveScroll(_pubScroll, true));
  }

  @override
  void dispose() {
    _tab.dispose();
    _mineScroll.dispose();
    _pubScroll.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  TagCategoryDef get _def => tagCategoryDef(_cat);

  Set<String> get _sel => _selected[_cat] ??= {};

  void _toggle(TagEntry e) {
    setState(() {
      if (_sel.contains(e.id)) {
        _sel.remove(e.id);
      } else if (_sel.length < _def.maxSelectable) {
        _sel.add(e.id);
      } else {
        hintSnack(
          context,
          '最多选 ${_def.maxSelectable} 个',
          icon: Icons.block_outlined,
        );
      }
    });
  }

  /// 滚动记忆的账本 key:每个分类的两个 scope 各记各的。
  String _scrollKey(TagCategory c, bool pub) =>
      'inspiration.${c.name}.${pub ? 'public' : 'mine'}';

  /// 持续记账(内容不可滚时跳过,否则会把记忆冲成 0)。
  void _saveScroll(ScrollController ctrl, bool pub) {
    if (!ctrl.hasClients || ctrl.positions.length != 1) return;
    final p = ctrl.position;
    if (!p.hasContentDimensions || p.maxScrollExtent <= 0) return;
    ScrollMemory.write(_scrollKey(_cat, pub), p.pixels);
  }

  void _jumpTo(ScrollController ctrl, double want) {
    if (!ctrl.hasClients || ctrl.positions.length != 1) return;
    final p = ctrl.position;
    if (!p.hasContentDimensions) return;
    final target = want.clamp(0.0, p.maxScrollExtent);
    if ((p.pixels - target).abs() > 1) ctrl.jumpTo(target);
  }

  void _switchCategory(TagCategory c) {
    if (c == _cat) return;
    // 目标位置必须在换 _cat **之前**读:换完之后旧偏移还挂在同一个控制器上,
    // 记账监听会先把旧值写进新分类的账,读到的就不是原位了。
    final wantMine = ScrollMemory.read(_scrollKey(c, false)) ?? 0;
    final wantPub = ScrollMemory.read(_scrollKey(c, true)) ?? 0;
    setState(() {
      _cat = c;
      _search = '';
      _filter = null;
      if (!tagCategoryDef(c).hasPublic) _tab.index = 0;
    });
    // 新分类的列表要等这一帧布好才有 maxScrollExtent,落位排到帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpTo(_mineScroll, wantMine);
      _jumpTo(_pubScroll, wantPub);
    });
  }

  // ---- 数据 ----

  bool _matches(TagEntry e, String q) {
    if (q.isEmpty) return true;
    bool has(String s) => s.toLowerCase().contains(q);
    return has(e.name) ||
        has(e.positive) ||
        e.aliases.any(has) ||
        e.tags.any(has);
  }

  /// 标签被删(标签池管理里删掉正在筛选的那个)后按「全部」处理,
  /// 不让列表空掉却没有任何选中态。
  String? _validFilter(TagLibraryState lib) {
    final f = _filter;
    if (f == null || f == _kFavFilter) return f;
    return lib.knownTags(_cat).contains(f) ? f : null;
  }

  /// 「我的」的完整来源 = 本地条目 + 公共库里我发布的(本地没副本的补进来,
  /// 标 created;对齐 web mineAll)。归属判定优先 owner_id,与服务端一致。
  List<TagEntry> _mineAll(TagLibraryState lib) {
    final local = lib.of(_cat);
    if (!_def.hasPublic) return local;
    final myId = ref.watch(botSessionProvider).value?.botUserId;
    final pub = ref.watch(publicTagsProvider(_cat)).value;
    if (myId == null || pub == null) return local;
    final haveId = {for (final e in local) e.publicId};
    final haveName = {for (final e in local) e.name};
    return [
      ...local,
      for (final p in pub)
        if (p.createdBy == myId &&
            !haveId.contains(p.publicId) &&
            !haveName.contains(p.name))
          p.copyWith(origin: TagOrigin.created),
    ];
  }

  List<TagEntry> _mineList(TagLibraryState lib) {
    final q = _search.trim().toLowerCase();
    var list = [
      for (final e in _mineAll(lib))
        if (_matches(e, q)) e,
    ];
    final filter = _validFilter(lib);
    if (filter == _kFavFilter) {
      list = [
        for (final e in list)
          if (e.origin == TagOrigin.favorited) e,
      ];
    } else if (filter != null) {
      list = [
        for (final e in list)
          if (e.tags.contains(filter)) e,
      ];
    }
    _sort(list);
    return list;
  }

  List<TagEntry> _publicList(List<TagEntry> all) {
    final q = _search.trim().toLowerCase();
    final list = [
      for (final e in all)
        if (_matches(e, q)) e,
    ];
    _sort(list);
    return list;
  }

  /// 画风按编号自然序(A1<A2<A10);其余最新在前。
  void _sort(List<TagEntry> list) {
    if (_cat == TagCategory.artist) {
      list.sort((a, b) => naturalCompare(a.name, b.name));
    } else {
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
  }

  // ---- 回填(语义对齐 web;app 编辑器无芯片协议,按约定插裸内容) ----

  List<TagEntry> _resolveSelected(TagLibraryState lib) {
    final byId = {for (final e in lib.of(_cat)) e.id: e};
    final pub = ref.read(publicTagsProvider(_cat)).value;
    if (pub != null) {
      for (final e in pub) {
        byId[e.id] = e;
      }
    }
    return [
      for (final id in _sel)
        if (byId[id] case final TagEntry e) e,
    ];
  }

  Future<void> _afterConfirm(List<TagEntry> used, String message) async {
    await ref.read(tagLibraryProvider.notifier).markUsed(_cat, [
      for (final e in used) e.id,
    ]);
    // 公共画师串使用计数上报(fire-and-forget)
    if (_cat == TagCategory.artist) {
      final session = ref.read(botSessionProvider).value;
      if (session != null) {
        final client = ref.read(backendClientProvider);
        for (final e in used) {
          if (e.id.startsWith('pub_') && e.publicId != null) {
            client.reportArtistUse(session.sessionId, e.publicId!);
          }
        }
      }
    }
    setState(() => _sel.clear());
    if (!mounted) return;
    hintSnack(context, message, icon: Icons.check_circle_outline);
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
  }

  /// 角色 → 加入角色卡(带名追加,上限 6 截断)。
  Future<void> _confirmAsCharacters(TagLibraryState lib) async {
    final entries = _resolveSelected(lib);
    if (entries.isEmpty) return;
    final added = ref.read(generateProvider.notifier).addNamedCharactersFrom([
      for (final e in entries)
        (name: e.name, positive: e.positive, negative: e.negative),
    ]);
    if (added == 0) {
      hintSnack(context, '角色已满 6 个', icon: Icons.block_outlined);
      return;
    }
    await _afterConfirm(
      entries,
      added < entries.length ? '已加入 $added 个角色(超出 6 个截断)' : '已加入 $added 个角色',
    );
  }

  /// 角色「主提示词」/ 画风/场景/其他「确认选择」:正负向拼进主提示词。
  Future<void> _confirmToPrompt(TagLibraryState lib) async {
    final entries = _resolveSelected(lib);
    if (entries.isEmpty) return;
    final gen = ref.read(generateProvider);
    ref
        .read(generateProvider.notifier)
        .setPrompts(
          positive: appendTagPositives(gen.prompt, entries),
          negative: appendTagNegatives(gen.negativePrompt, entries),
        );
    await _afterConfirm(entries, '已加入提示词');
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = context.scheme;
    final lib = ref.watch(tagLibraryProvider).value ?? const TagLibraryState();
    final def = _def;

    return Scaffold(
      body: Column(
        children: [
          _topBar(scheme, lib),
          Padding(
            padding: const EdgeInsets.fromLTRB(_kEdge, 8, _kEdge, 0),
            child: TextField(
              key: ValueKey('tag-search-${def.webId}'),
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: def.searchHint,
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
          if (def.hasPublic)
            Padding(
              // 「我的」下面紧跟筛选行,间距由它顶出,这里不再留底距;
              // 公共态没有筛选行,分段行会直接贴上网格首个分组头(顶衬仅 2),
              // 补一档底距回到与上方各行相同的 8 节奏。
              padding: EdgeInsets.fromLTRB(
                _kEdge,
                8,
                _kEdge,
                _tabIndex == 0 ? 0 : 8,
              ),
              child: _segTabs(scheme, lib.of(_cat).length),
            ),
          if (_tabIndex == 0 || !def.hasPublic) _filterChips(lib),
          Expanded(
            // 禁 TabBarView 横滑:横滑手势留给 shell PageView 切底部 tab
            // (与场景/其他分类行为一致),scope 切换走分段控件点按。
            child: def.hasPublic
                ? TabBarView(
                    controller: _tab,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [_mineTab(lib), _publicTab(lib)],
                  )
                : _mineTab(lib),
          ),
        ],
      ),
      bottomNavigationBar: _selectionBar(scheme, lib),
    );
  }

  Widget _topBar(ColorScheme scheme, TagLibraryState lib) {
    return Padding(
      // 行尾是 IconButton:右边距减去它的内衬,图标视觉边与其他行对齐
      padding: const EdgeInsets.fromLTRB(_kEdge, 6, _kIconEdge, 0),
      child: Row(
        children: [
          _categoryPill(scheme, lib),
          const Spacer(),
          IconButton(
            tooltip: '数据备份',
            icon: const Icon(Icons.cloud_outlined),
            onPressed: () => showTagBackupSheet(context, ref),
          ),
          IconButton(
            tooltip: '新建',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(
              context,
            ).push(sharedAxisRoute(TagEditorPage(cat: _cat))),
          ),
        ],
      ),
    );
  }

  /// 分类切换:整块 filled 胶囊(图标+名称+计数+▾),点开下拉选分类。
  Widget _categoryPill(ColorScheme scheme, TagLibraryState lib) {
    return PopupMenuButton<TagCategory>(
      tooltip: '切换分类',
      offset: const Offset(0, 50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: _switchCategory,
      itemBuilder: (_) => [
        for (final d in kTagCategoryDefs)
          PopupMenuItem(
            value: d.key,
            child: Row(
              children: [
                Icon(
                  d.icon,
                  size: 19,
                  color: d.key == _cat
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  d.label,
                  style: TextStyle(
                    fontWeight: d.key == _cat
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
                const Spacer(),
                if (d.key == _cat)
                  Icon(Icons.check, size: 16, color: scheme.primary),
              ],
            ),
          ),
      ],
      child: Container(
        height: 44,
        padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_def.icon, size: 19, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              _def.label,
              style: context.texts.titleMedium!.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${lib.of(_cat).length}',
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _segTabs(ColorScheme scheme, int mineCount) {
    return SizedBox(
      height: 42,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            // 视觉层:滑动指示器 + 渐变标签(随 tab 动画重建,无手势)。
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _tab.animation!,
                builder: (context, _) {
                  final t = _tab.animation!.value.clamp(0.0, 1.0);
                  return LayoutBuilder(
                    builder: (context, c) {
                      final segW = c.maxWidth / 2;
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
                              _segLabel(
                                0,
                                Icons.bookmark_outline,
                                '我的 · $mineCount',
                                t,
                              ),
                              _segLabel(1, Icons.public, '公共库', t),
                            ],
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            // 手势层:稳定不重建,整段任意位置可点。
            Positioned.fill(
              child: Row(
                children: [
                  for (var i = 0; i < 2; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _tab.animateTo(i),
                        child: const SizedBox.expand(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segLabel(int i, IconData icon, String label, double t) {
    final scheme = context.scheme;
    final sel = i == 0 ? 1 - t : t;
    final color = Color.lerp(scheme.onSurfaceVariant, scheme.primary, sel);
    return Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: context.texts.labelLarge!.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// 「全部 / 收藏 / 标签…」筛选行(我的 scope;标签=池∪在用)。
  /// 药丸 chip + 主色实底标记选中,与 Vibe 管理器同款。
  Widget _filterChips(TagLibraryState lib) {
    final scheme = context.scheme;
    final tags = lib.knownTags(_cat);
    final filter = _validFilter(lib);
    Widget chip(String label, bool sel, VoidCallback onTap, {IconData? icon}) =>
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            // 图标放进 label(自控间距),不用 avatar(默认间距太大)
            label: icon == null
                ? Text(label)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: sel ? scheme.onPrimary : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 3),
                      Text(label),
                    ],
                  ),
            selected: sel,
            onSelected: (_) => onTap(),
            visualDensity: VisualDensity.compact,
            shape: const StadiumBorder(),
            labelStyle: context.texts.labelMedium!.copyWith(
              fontWeight: FontWeight.w600,
              color: sel ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
            selectedColor: scheme.primary,
            backgroundColor: scheme.surfaceContainerHigh,
            side: BorderSide.none,
            showCheckmark: false,
          ),
        );
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            // 横向滚动:标签再多也不会溢出
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(_kEdge, 4, 4, 4),
              children: [
                chip(
                  '全部',
                  filter == null,
                  () => setState(() => _filter = null),
                ),
                chip(
                  '收藏',
                  filter == _kFavFilter,
                  () => setState(() => _filter = _kFavFilter),
                  icon: Icons.star_rounded,
                ),
                for (final t in tags)
                  chip(
                    t,
                    filter == t,
                    () => setState(() => _filter = _filter == t ? null : t),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '标签池管理',
            icon: Icon(
              Icons.settings_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () => showTagPoolSheet(context, ref, _cat),
          ),
          const SizedBox(width: _kIconEdge),
        ],
      ),
    );
  }

  // ---- 我的 / 公共库 ----

  Widget _mineTab(TagLibraryState lib) {
    final list = _mineList(lib);
    if (list.isEmpty) {
      return _empty(
        _search.isNotEmpty || _filter != null
            ? '没有匹配的${_def.label}'
            : '还没有${_def.label},点右上角 + 新建',
      );
    }
    // 自建/我发布的在上,公共库收藏来的单独一组在下(对齐 web)
    final mine = [
      for (final e in list)
        if (e.origin != TagOrigin.favorited) e,
    ];
    final fav = [
      for (final e in list)
        if (e.origin == TagOrigin.favorited) e,
    ];
    final groups = <_Group>[
      if (mine.isNotEmpty)
        (
          header: _sectionHeader(
            Icons.favorite,
            '我的${_def.label}',
            mine.length,
          ),
          items: mine,
        ),
      if (fav.isNotEmpty)
        (
          header: _sectionHeader(
            Icons.star_rounded,
            '收藏的${_def.label}',
            fav.length,
            muted: true,
          ),
          items: fav,
        ),
    ];
    return _railWrap(groups, _mineScroll, _grid(groups, _mineScroll, false));
  }

  Widget _publicTab(TagLibraryState lib) {
    final async = ref.watch(publicTagsProvider(_cat));
    // 骨架 → 内容之间淡入淡出,不硬切
    return AnimatedSwitcher(
      duration: Motion.medium,
      child: KeyedSubtree(
        key: ValueKey(
          async.isLoading
              ? 'sk'
              : async.hasError
              ? 'err'
              : 'data',
        ),
        child: _publicContent(async),
      ),
    );
  }

  Widget _publicContent(AsyncValue<List<TagEntry>> async) {
    return async.when(
      loading: () => _SkeletonGrid(aspect: _cardAspect),
      error: (e, _) {
        // 会话过期后端回 401/403,与无会话同样给「去授权」出口,
        // 别让人困在「重试永远失败」里。
        final needBot =
            (e is StateError && e.message == 'need-bot') ||
            (e is BackendException && (e.status == 401 || e.status == 403));
        if (needBot) {
          return _empty(
            '公共库需要 Bot 授权',
            action: (
              '去授权',
              () => ref.read(shellIndexProvider.notifier).select(kTabProfile),
            ),
          );
        }
        return _empty(
          '公共库加载失败',
          action: ('重试', () => ref.invalidate(publicTagsProvider(_cat))),
        );
      },
      data: (all) {
        final list = _publicList(all);
        if (list.isEmpty) {
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(publicTagsProvider(_cat)),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: 320,
                  child: _empty(
                    _search.isNotEmpty ? '没有匹配的${_def.label}' : '公共库暂无内容',
                  ),
                ),
              ],
            ),
          );
        }
        final groups = <_Group>[
          (
            header: _sectionHeader(
              Icons.public,
              '公共${_def.label}',
              list.length,
            ),
            items: list,
          ),
        ];
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(publicTagsProvider(_cat)),
          child: _railWrap(groups, _pubScroll, _grid(groups, _pubScroll, true)),
        );
      },
    );
  }

  Widget _sectionHeader(
    IconData icon,
    String label,
    int count, {
    bool muted = false,
  }) {
    final scheme = context.scheme;
    final color = muted ? scheme.onSurfaceVariant : scheme.primary;
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: context.texts.labelLarge!.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: context.texts.labelMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: scheme.outlineVariant, height: 1)),
        ],
      ),
    );
  }

  Widget _empty(String text, {(String, VoidCallback)? action}) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_def.icon, size: 44, color: scheme.outlineVariant),
          const SizedBox(height: 10),
          Text(
            text,
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 10),
            FilledButton.tonal(onPressed: action.$2, child: Text(action.$1)),
          ],
        ],
      ),
    );
  }

  // ---- 网格 + 字母导航 ----

  static const _headerH = 32.0;

  /// 卡片 = 预览图比例:cover 下整图完整铺满、不裁切。
  double get _cardAspect => _def.previewAspect;

  Widget _grid(List<_Group> groups, ScrollController ctrl, bool isPublic) {
    // 有 publicId 的条目(收藏/我发布的)一律用当前公共库的 http 预览:
    // 随当前后端地址,不受备份剥离本机预览、也不受端口变化影响。
    final pubPreview = <String, String>{
      for (final p
          in ref.read(publicTagsProvider(_cat)).value ?? const <TagEntry>[])
        if (p.publicId != null && p.previewUrl != null)
          p.publicId!: p.previewUrl!,
    };
    return CustomScrollView(
      controller: ctrl,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        for (final g in groups) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_kEdge, 2, _kEdge, 0),
            sliver: SliverToBoxAdapter(child: g.header),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_kEdge, 8, _kEdge, 16),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: _gap,
                crossAxisSpacing: _gap,
                childAspectRatio: _cardAspect,
              ),
              delegate: SliverChildBuilderDelegate((context, i) {
                final e = g.items[i];
                final preview =
                    (e.publicId != null ? pubPreview[e.publicId] : null) ??
                    e.previewUrl;
                return _TagCard(
                  key: ValueKey(e.id),
                  entry: e,
                  previewUrl: preview,
                  selected: _sel.contains(e.id),
                  isPublic: isPublic,
                  collected:
                      isPublic &&
                      ref
                          .read(tagLibraryProvider.notifier)
                          .isCollected(
                            _cat,
                            publicId: e.publicId,
                            name: e.name,
                          ),
                  onTap: () => _toggle(e),
                  onLongPress: () => showTagDetailSheet(context, e),
                  onCollect: isPublic ? () => _collect(e) : null,
                  onMenu: isPublic ? null : (v) => _cardMenu(v, e),
                );
              }, childCount: g.items.length),
            ),
          ),
        ],
      ],
    );
  }

  /// 画风分类包一层右缘字母导航。
  Widget _railWrap(List<_Group> groups, ScrollController ctrl, Widget child) {
    final total = groups.fold(0, (n, g) => n + g.items.length);
    if (!_def.alphabetRail || total < 12) return child;
    // 用 Set 去重:'#' 桶(数字开头排最前、CJK 排最后)可能不相邻,
    // 只留首次出现,跳转恒到首个。
    final seen = <String>{};
    final letters = <String>[
      for (final g in groups)
        for (final e in g.items)
          if (seen.add(letterOfName(e.name))) letterOfName(e.name),
    ];
    return Stack(
      children: [
        child,
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: _LetterRail(
            letters: letters,
            onSelect: (l) => _jumpToLetter(groups, ctrl, l),
          ),
        ),
      ],
    );
  }

  void _jumpToLetter(List<_Group> groups, ScrollController ctrl, String l) {
    if (!ctrl.hasClients) return;
    final w = context.size?.width ?? 400;
    final itemW = (w - _kEdge * 2 - _gap) / 2;
    final rowExtent = itemW / _cardAspect + _gap;
    // 逐组累加(组头 + 该组行高),命中组内再按行偏移
    var offset = 0.0;
    for (final g in groups) {
      final i = g.items.indexWhere((e) => letterOfName(e.name) == l);
      final rows = (g.items.length + 1) ~/ 2;
      if (i >= 0) {
        offset += 2 + _headerH + 8 + (i ~/ 2) * rowExtent;
        ctrl.jumpTo(offset.clamp(0.0, ctrl.position.maxScrollExtent));
        return;
      }
      offset += 2 + _headerH + 8 + rows * rowExtent + 16;
    }
  }

  Future<void> _collect(TagEntry e) async {
    final ok = await ref.read(tagLibraryProvider.notifier).collect(e);
    if (!mounted) return;
    hintSnack(
      context,
      ok ? '已收藏到「我的」' : '已经收藏过了',
      icon: ok ? Icons.favorite : Icons.info_outline,
    );
  }

  // ---- 批量操作(底栏第一层) ----

  /// 批量行的小描边按钮(与 Vibe 管理器同款)。
  Widget _pillBtn({
    required IconData icon,
    required String label,
    Color? color,
    VoidCallback? onTap,
  }) {
    final scheme = context.scheme;
    final enabled = onTap != null;
    final fg = (color ?? scheme.onSurfaceVariant).withValues(
      alpha: enabled ? 1 : .45,
    );
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 5),
              Text(label, style: context.texts.labelLarge!.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runBatch(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 批量贴标签:选一个标签(可现场新建)并入所有选中条目。
  Future<void> _batchTag(TagLibraryState lib) async {
    final entries = _resolveSelected(lib);
    if (entries.isEmpty) return;
    final tag = await pickTagSheet(context, ref, _cat);
    if (tag == null || !mounted) return;
    await _runBatch(() async {
      final notifier = ref.read(tagLibraryProvider.notifier);
      await notifier.addPoolTag(_cat, tag);
      var n = 0;
      for (final e in entries) {
        if (e.tags.contains(tag)) continue;
        await notifier.upsert(e.copyWith(tags: [...e.tags, tag]..sort()));
        n++;
      }
      if (mounted) {
        hintSnack(context, '已给 $n 项加上「$tag」', icon: Icons.sell_outlined);
      }
    });
  }

  /// 批量删除:已发布的连同公共库条目一并删。
  Future<void> _batchDelete(TagLibraryState lib) async {
    final entries = _resolveSelected(lib);
    if (entries.isEmpty) return;
    final published = [
      for (final e in entries)
        if (e.origin == TagOrigin.created && e.publicId != null) e,
    ];
    final ok = await confirmDialog(
      context,
      title: '删除 ${entries.length} 项?',
      message: published.isEmpty
          ? '仅删除本地条目,不可恢复。'
          : '其中 ${published.length} 项已发布,将同时从公共库删除。不可恢复。',
      confirmLabel: '删除',
    );
    if (!ok || !mounted) return;
    await _runBatch(() async {
      final notifier = ref.read(tagLibraryProvider.notifier);
      final client = ref.read(backendClientProvider);
      final session = ref.read(botSessionProvider).value;
      var done = 0, failed = 0;
      for (final e in entries) {
        try {
          if (e.origin == TagOrigin.created &&
              e.publicId != null &&
              session != null) {
            if (_cat == TagCategory.character) {
              await client.deletePublicOc(session.sessionId, e.publicId!);
            } else {
              await client.deletePublicArtist(session.sessionId, e.publicId!);
            }
          }
          await notifier.remove(e.id);
          done++;
        } catch (_) {
          failed++;
        }
      }
      if (published.isNotEmpty) ref.invalidate(publicTagsProvider(_cat));
      if (!mounted) return;
      setState(() => _sel.clear());
      hintSnack(
        context,
        failed == 0 ? '已删除 $done 项' : '已删除 $done 项,$failed 项失败',
        icon: Icons.delete_outline,
      );
    });
  }

  /// 批量收藏(公共库 scope)。
  Future<void> _batchCollect(TagLibraryState lib) async {
    final entries = _resolveSelected(lib);
    if (entries.isEmpty) return;
    await _runBatch(() async {
      final notifier = ref.read(tagLibraryProvider.notifier);
      var added = 0;
      for (final e in entries) {
        if (await notifier.collect(e)) added++;
      }
      if (!mounted) return;
      setState(() => _sel.clear());
      hintSnack(
        context,
        added == entries.length ? '已收藏 $added 项' : '已收藏 $added 项(其余已在库中)',
        icon: Icons.favorite,
      );
    });
  }

  Future<void> _cardMenu(String action, TagEntry e) async {
    switch (action) {
      case 'edit':
        Navigator.of(
          context,
        ).push(sharedAxisRoute(TagEditorPage(cat: _cat, edit: e)));
      case 'copy':
        await Clipboard.setData(ClipboardData(text: e.positive));
        if (mounted) hintSnack(context, '已复制提示词', icon: Icons.copy);
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: '删除「${e.name}」?',
          message: '仅删除本地条目,不可恢复。',
          confirmLabel: '删除',
        );
        if (ok) {
          _sel.remove(e.id);
          await ref.read(tagLibraryProvider.notifier).remove(e.id);
        }
    }
  }

  // ---- 底部操作条 ----

  /// 角色分类的动作:一体式分段胶囊 —— 左「主提示词」右「加入角色 N」,
  /// 同一主色底,中间发丝分隔,整体一颗药丸。
  Widget _splitAction(ColorScheme scheme, TagLibraryState lib, int n) {
    final bg = scheme.primary;
    final fg = scheme.onPrimary;
    Widget seg({
      required int flex,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) => Expanded(
      flex: flex,
      child: Material(
        color: bg,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.labelLarge!.copyWith(
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return SizedBox(
      height: 48,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Row(
          children: [
            seg(
              flex: 5,
              icon: Icons.bolt_outlined,
              label: '主提示词',
              onTap: () => _confirmToPrompt(lib),
            ),
            Container(width: 1.5, color: scheme.surfaceContainer),
            seg(
              flex: 6,
              icon: Icons.person_add_alt,
              label: '加入角色',
              onTap: () => _confirmAsCharacters(lib),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectionBar(ColorScheme scheme, TagLibraryState lib) {
    final n = _sel.length;
    final publicScope = _def.hasPublic && _tabIndex == 1;
    return ExpandBody(
      expanded: n > 0,
      child: Material(
        color: scheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 第一层:批量操作(清空已并入第二层「取消选择」)
              Row(
                children: [
                  if (publicScope)
                    _pillBtn(
                      icon: Icons.favorite_border,
                      label: '收藏',
                      onTap: _busy ? null : () => _batchCollect(lib),
                    )
                  else
                    _pillBtn(
                      icon: Icons.sell_outlined,
                      label: '标签',
                      onTap: _busy ? null : () => _batchTag(lib),
                    ),
                  const Spacer(),
                  // 破坏性操作靠右,与其他批量项拉开距离
                  if (!publicScope)
                    _pillBtn(
                      icon: Icons.delete_outline,
                      label: '删除',
                      color: scheme.error,
                      onTap: _busy ? null : () => _batchDelete(lib),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              // 第二层:取消选择(定宽)+ 右侧动作(角色=一体式分段按钮)
              Row(
                children: [
                  OutlinedButton(
                    onPressed: () => setState(() => _sel.clear()),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(112, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: const Text('取消选择'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _cat == TagCategory.character
                        ? _splitAction(scheme, lib, n)
                        : FilledButton.icon(
                            onPressed: () => _confirmToPrompt(lib),
                            icon: const Icon(Icons.check, size: 18),
                            label: Text('确认选择 ($n)'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
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
}

// ---- 卡片 ----

/// 公共库加载态:骨架网格(卡片形状 + 呼吸微光),比干等一个转圈更有"内容在来"。
class _SkeletonGrid extends StatefulWidget {
  const _SkeletonGrid({required this.aspect});

  final double aspect;

  @override
  State<_SkeletonGrid> createState() => _SkeletonGridState();
}

class _SkeletonGridState extends State<_SkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return GridView.count(
      crossAxisCount: 2,
      padding: const EdgeInsets.fromLTRB(_kEdge, 42, _kEdge, 16),
      mainAxisSpacing: _gap,
      crossAxisSpacing: _gap,
      childAspectRatio: widget.aspect,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 6; i++)
          FadeTransition(
            opacity: Tween(
              begin: .35,
              end: .7,
            ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
      ],
    );
  }
}

/// 图片加载完淡入(缓存命中的同步图不淡),让预览逐张柔和显现而非硬蹦。
Widget _fadeInFrame(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSync,
) {
  if (wasSync) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: Motion.medium,
    curve: Curves.easeOut,
    child: child,
  );
}

/// 网格卡:预览图(无图=名称定色相的斜纹占位)+ 底部名称条 + 来源角标;
/// 左上选择圈,右上 ⋮(我的)/ ❤ 收藏(公共)。点卡选择,长按看详情。
class _TagCard extends StatelessWidget {
  const _TagCard({
    super.key,
    required this.entry,
    this.previewUrl,
    required this.selected,
    required this.isPublic,
    this.collected = false,
    required this.onTap,
    required this.onLongPress,
    this.onCollect,
    this.onMenu,
  });

  final TagEntry entry;

  /// 实际渲染的预览(可能是按 publicId 从公共库补的 http,覆盖 entry 自身)。
  final String? previewUrl;
  final bool selected;
  final bool isPublic;
  final bool collected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onCollect;
  final ValueChanged<String>? onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return AnimatedContainer(
      duration: Motion.fast,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.8 : 1,
        ),
      ),
      child: Material(
        color: scheme.surfaceContainer,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              switch (previewUrl) {
                null => _HueStripes(name: entry.name),
                final u when u.startsWith('http') => Image.network(
                  u,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  frameBuilder: _fadeInFrame,
                  errorBuilder: (_, _, _) => _HueStripes(name: entry.name),
                ),
                final u => Image.file(
                  File(u),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  frameBuilder: _fadeInFrame,
                  errorBuilder: (_, _, _) => _HueStripes(name: entry.name),
                ),
              },
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 14, 8, 7),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: .62),
                      ],
                    ),
                  ),
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: selected ? scheme.primary : Colors.white,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 7,
                left: 7,
                child: AnimatedContainer(
                  duration: Motion.fast,
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? scheme.primary
                        : Colors.black.withValues(alpha: .3),
                    border: selected
                        ? null
                        : Border.all(color: Colors.white70, width: 1.5),
                  ),
                  child: selected
                      ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
                      : null,
                ),
              ),
              // 公共卡:右上角收藏钮(40px 圆钮 + 半透明底,已收藏=实心红心);
              // 我的卡:右上角 ⋮ 菜单。
              if (isPublic)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Material(
                    color: collected
                        ? Colors.white.withValues(alpha: .92)
                        : Colors.black.withValues(alpha: .42),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: onCollect,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(
                          collected ? Icons.favorite : Icons.favorite_border,
                          size: 21,
                          color: collected ? scheme.error : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              if (!isPublic)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Material(
                    color: Colors.black.withValues(alpha: .42),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: PopupMenuButton<String>(
                        onSelected: onMenu,
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.more_vert,
                          size: 20,
                          color: Colors.white,
                        ),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: _MenuRow(Icons.edit_outlined, '编辑'),
                          ),
                          const PopupMenuItem(
                            value: 'copy',
                            child: _MenuRow(Icons.copy, '复制提示词'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: _MenuRow(
                              Icons.delete_outline,
                              '删除',
                              danger: true,
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
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.danger = false});

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = danger ? context.scheme.error : context.scheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: danger ? c : null)),
      ],
    );
  }
}

/// 无预览图的占位:名称哈希定色相的深色渐变 + 斜纹 + 名称水印
/// (对齐 web HorizontalCard 的 hashHue 占位,同名恒同色)。
class _HueStripes extends StatelessWidget {
  const _HueStripes({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    return CustomPaint(
      painter: _HueStripePainter(hue),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            name.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
              color: Colors.white.withValues(alpha: .2),
            ),
          ),
        ),
      ),
    );
  }
}

class _HueStripePainter extends CustomPainter {
  const _HueStripePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final a = HSLColor.fromAHSL(1, hue, .38, .20).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 24) % 360, .42, .13).toColor();
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [a, b],
        ).createShader(Offset.zero & size),
    );
    final stripe = Paint()..color = Colors.black.withValues(alpha: .16);
    const w = 14.0;
    for (double x = -size.height; x < size.width; x += w * 2.4) {
      final path = Path()
        ..moveTo(x, size.height)
        ..lineTo(x + size.height, 0)
        ..lineTo(x + size.height + w, 0)
        ..lineTo(x + w, size.height)
        ..close();
      canvas.drawPath(path, stripe);
    }
  }

  @override
  bool shouldRepaint(covariant _HueStripePainter old) => old.hue != hue;
}

/// 右缘字母导航条(画风):点按/竖向拖动跳转到该字母首个条目。
class _LetterRail extends StatefulWidget {
  const _LetterRail({required this.letters, required this.onSelect});

  final List<String> letters;
  final ValueChanged<String> onSelect;

  @override
  State<_LetterRail> createState() => _LetterRailState();
}

class _LetterRailState extends State<_LetterRail> {
  String? _last;

  void _pick(Offset local, double height) {
    final n = widget.letters.length;
    if (n == 0 || height <= 0) return;
    final i = (local.dy / height * n).clamp(0, n - 1).toInt();
    final l = widget.letters[i];
    if (l != _last) {
      _last = l;
      HapticFeedback.selectionClick();
      widget.onSelect(l);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Center(
      child: Builder(
        builder: (railCtx) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) {
            final box = railCtx.findRenderObject() as RenderBox?;
            if (box != null) {
              _pick(box.globalToLocal(d.globalPosition), box.size.height);
            }
          },
          onVerticalDragEnd: (_) => _last = null,
          onTapDown: (d) {
            final box = railCtx.findRenderObject() as RenderBox?;
            if (box != null) {
              _last = null;
              _pick(box.globalToLocal(d.globalPosition), box.size.height);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            // 小屏/字母多时等比缩小,不溢出;命中映射按实际渲染高度线性算,不受影响
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final l in widget.letters)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Text(
                        l,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
