import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/net/remote_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/image_ops.dart' show decodeImageSize, img2imgResolution;
import '../generate/generate_state.dart';
import '../generate/models.dart'
    show crSupportsModel, providerOfModel, GenProvider;
import '../generate/widgets/common.dart' show hintSnack, sharedAxisRoute;
import '../char_library/char_library.dart';
import '../local_gallery/local_gallery_state.dart';
import '../shell/shell_state.dart';
import '../inspiration/codex/codex_view.dart';
import '../inspiration/prompt_library_save.dart';
import 'online_gallery_credentials.dart';
import 'online_gallery_credentials_sheet.dart';
import 'online_gallery_import_sheet.dart';
import 'online_gallery_models.dart';
import 'online_gallery_service.dart';
import 'online_gallery_tag_chips.dart';
import '../editor/data/suggestions.dart' show translationOf;

// Keep the scroll bucket beside the cached gallery data, beyond a route's life.
final onlineGalleryScrollStorageProvider = Provider(
  (ref) => PageStorageBucket(),
);

/// 搜索框联想的一条:联想本身、当时光标那个词、选它之后整个搜索框的内容。
typedef _SuggestPick = ({
  GalleryTagSuggestion suggestion,
  String term,
  String query,
});

/// Multi-source online reference gallery.
class OnlineGalleryPage extends ConsumerStatefulWidget {
  const OnlineGalleryPage({super.key, this.embedded = false});

  /// 嵌在灵感页的页签里:不带自己的 AppBar(顶上已经是页签栏),
  /// 黑名单、刷新挪进来源那一行。
  final bool embedded;

  @override
  ConsumerState<OnlineGalleryPage> createState() => _OnlineGalleryPageState();
}

class _OnlineGalleryPageState extends ConsumerState<OnlineGalleryPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  Timer? _debounce;
  bool _showFilters = false;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(onlineGalleryProvider).query;
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  OnlineGalleryNotifier get _notifier =>
      ref.read(onlineGalleryProvider.notifier);

  void _onScroll() => _maybeLoadMore();

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final state = ref.read(onlineGalleryProvider);
    if ((state.source == OnlineGallerySource.aiTag &&
            state.excludesAllAiPlatforms) ||
        state.error != null ||
        state.feed == OnlineGalleryFeed.favorites ||
        !state.hasMore ||
        state.loading ||
        state.loadingMore ||
        _scroll.position.extentAfter >= 1000) {
      return;
    }
    unawaited(_notifier.load(append: true));
  }

  /// A masonry page can be shorter than the viewport (especially on an iPad
  /// in landscape), so there may be no user scroll event to trigger pagination.
  /// Check after layout and keep filling until the viewport has a useful tail.
  void _scheduleLoadMoreCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(onlineGalleryProvider);
      if ((state.source == OnlineGallerySource.aiTag &&
              state.excludesAllAiPlatforms) ||
          state.error != null ||
          state.feed == OnlineGalleryFeed.favorites ||
          !state.hasMore ||
          state.loading ||
          state.loadingMore) {
        return;
      }
      if (!_scroll.hasClients || _scroll.position.extentAfter < 1000) {
        unawaited(_notifier.load(append: true));
      }
    });
  }

  /// 搜索框联想:光标所在那个词停顿一下再去问(打字途中不每个字母都问)。
  /// 过期的结果 RawAutocomplete 自己会丢,这里只管少问几次。
  Future<Iterable<_SuggestPick>> _suggestFor(
    TextEditingValue value,
    OnlineGallerySource source,
  ) async {
    if (source == OnlineGallerySource.codex) return const [];
    final word = galleryQueryWordAt(value);
    if (word == null || !galleryWorthSuggesting(word.term)) return const [];
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted || _search.text != value.text) return const [];
    final list = await ref
        .read(onlineGalleryServiceProvider)
        .suggestTags(source, word.term);
    return [
      for (final s in list)
        (
          suggestion: s,
          term: word.term,
          // AI TAG 搜的是提示词原文(空格写法),标签站认下划线
          query: galleryQueryReplace(
            word,
            source == OnlineGallerySource.aiTag ? s.label : s.value,
          ),
        ),
    ];
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _notifier.setQuery(value);
      _notifier.load();
    });
  }

  Future<void> _editBlacklist() async {
    final state = ref.read(onlineGalleryProvider);
    final controller = TextEditingController(text: state.blacklist.join('\n'));
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('黑名单标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '每行一个标签，例如\nlowres\nwatermark',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    final tags = value
        .split(RegExp(r'[\n,，\s]+'))
        .map((tag) => tag.trim().toLowerCase().replaceAll(' ', '_'))
        .where(
          (tag) => tag.isNotEmpty && !tag.contains(':') && !tag.contains('*'),
        )
        .toSet();
    _notifier.setBlacklist(tags);
  }

  Future<void> _pickRatings() async {
    final state = ref.read(onlineGalleryProvider);
    final selected = {...state.ratings};
    final value = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('内容分级')),
              for (final rating in OnlineGalleryRating.values)
                CheckboxListTile(
                  value: selected.contains(rating.key),
                  title: Text(rating.label),
                  secondary: Icon(_ratingIcon(rating)),
                  onChanged: (on) => setLocal(() {
                    on == true
                        ? selected.add(rating.key)
                        : selected.remove(rating.key);
                  }),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, selected),
                    child: const Text('应用筛选'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (value != null) _notifier.setRatings(value);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onlineGalleryProvider);
    ref.listen(onlineGalleryProvider.select((state) => state.query), (
      _,
      query,
    ) {
      if (_search.text != query) _search.text = query;
    });
    final scheme = context.scheme;
    final body = Column(
      children: [
        _sourceBar(state, scheme),
        if (state.source == OnlineGallerySource.codex)
          const Expanded(child: CodexView())
        else ...[
          _feedBar(state, scheme),
          if (state.source == OnlineGallerySource.aiTag) _platformBar(state),
          _searchBar(state, scheme),
          AnimatedSize(
            duration: Motion.fast,
            child: _showFilters
                ? _filterBar(state, scheme)
                : const SizedBox.shrink(),
          ),
          Expanded(child: _content(state, scheme)),
        ],
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('在线画廊'),
        actions: [_blacklistButton(state, scheme), _refreshButton(state)],
      ),
      body: body,
    );
  }

  Widget _blacklistButton(OnlineGalleryState state, ColorScheme scheme) =>
      IconButton(
        tooltip: '黑名单',
        icon: Icon(
          state.blacklist.isEmpty ? Icons.block_outlined : Icons.block,
          color: state.blacklist.isEmpty ? null : scheme.error,
        ),
        onPressed: _editBlacklist,
      );

  Widget _refreshButton(OnlineGalleryState state) => IconButton(
    tooltip: '刷新',
    icon: const Icon(Icons.refresh),
    onPressed: state.loading ? null : () => _notifier.load(),
  );

  /// 当前来源填没填凭据:填了钥匙点亮。
  Widget _keyButton(OnlineGalleryState state, ColorScheme scheme) {
    final creds = ref.watch(onlineGalleryCredentialsProvider).value;
    final on = creds?.configuredFor(state.source) ?? false;
    return IconButton(
      tooltip: on ? 'API Key(已配置)' : 'API Key',
      icon: Icon(
        on ? Icons.key : Icons.key_outlined,
        color: on ? scheme.primary : null,
      ),
      onPressed: () => showOnlineGalleryCredentialsSheet(context),
    );
  }

  Widget _sourceBar(OnlineGalleryState state, ColorScheme scheme) {
    final codex = state.source == OnlineGallerySource.codex;
    return Padding(
      // 行尾是 IconButton 时右边距减去它的内衬,图标视觉边与下面各行对齐
      padding: EdgeInsets.fromLTRB(14, 8, codex ? 14 : 6, 4),
      child: Row(
        children: [
          Icon(Icons.public, size: 19, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: PopupMenuButton<OnlineGallerySource>(
              tooltip: '切换画廊来源',
              onSelected: _notifier.setSource,
              itemBuilder: (_) => [
                for (final source in OnlineGallerySource.values)
                  PopupMenuItem(
                    value: source,
                    child: Row(
                      children: [
                        Icon(
                          source == state.source ? Icons.check : Icons.public,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Text(source.label),
                      ],
                    ),
                  ),
              ],
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.source.label,
                        style: context.texts.bodyMedium!.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
          if (!codex) ...[
            const SizedBox(width: 2),
            _keyButton(state, scheme),
            if (widget.embedded) ...[
              _blacklistButton(state, scheme),
              _refreshButton(state),
            ],
          ],
        ],
      ),
    );
  }

  Widget _feedBar(OnlineGalleryState state, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<OnlineGalleryFeed>(
              segments: [
                const ButtonSegment(
                  value: OnlineGalleryFeed.search,
                  label: Text('搜索'),
                  icon: Icon(Icons.search, size: 16),
                ),
                if (state.source != OnlineGallerySource.gelbooru)
                  const ButtonSegment(
                    value: OnlineGalleryFeed.ranking,
                    label: Text('排行'),
                    icon: Icon(Icons.trending_up, size: 16),
                  ),
                const ButtonSegment(
                  value: OnlineGalleryFeed.favorites,
                  label: Text('收藏'),
                  icon: Icon(Icons.star_outline, size: 16),
                ),
              ],
              selected: {state.feed},
              onSelectionChanged: (selection) =>
                  _notifier.setFeed(selection.first),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '内容分级',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.tune,
              color: state.ratings.length < 4
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
            onPressed: _pickRatings,
          ),
        ],
      ),
    );
  }

  Widget _searchBar(OnlineGalleryState state, ColorScheme scheme) {
    final source = state.source;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: RawAutocomplete<_SuggestPick>(
        textEditingController: _search,
        focusNode: _searchFocus,
        displayStringForOption: (pick) => pick.query,
        optionsBuilder: (value) => _suggestFor(value, source),
        // 点一条就把光标那个词换掉并直接搜;回车照旧按原文搜(不抢选中项)
        onSelected: (pick) {
          _debounce?.cancel();
          _notifier.setQuery(pick.query);
          _notifier.load();
        },
        optionsViewBuilder: (context, onSelected, options) =>
            _suggestionList(context, scheme, onSelected, options.toList()),
        fieldViewBuilder: (context, controller, focusNode, _) => TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: _onSearchChanged,
          onSubmitted: (value) {
            _debounce?.cancel();
            _notifier.setQuery(value);
            _notifier.load();
          },
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: state.feed == OnlineGalleryFeed.ranking
                ? '搜索排行标签…'
                : '搜索标签…',
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.blacklist.isNotEmpty)
                  Icon(Icons.block, size: 17, color: scheme.error),
                IconButton(
                  tooltip: _showFilters ? '收起筛选' : '展开筛选',
                  icon: Icon(
                    _showFilters ? Icons.expand_less : Icons.expand_more,
                  ),
                  onPressed: () => setState(() => _showFilters = !_showFilters),
                ),
              ],
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
      ),
    );
  }

  Widget _suggestionList(
    BuildContext context,
    ColorScheme scheme,
    AutocompleteOnSelected<_SuggestPick> onSelected,
    List<_SuggestPick> options,
  ) {
    final highlighted = AutocompleteHighlightedOption.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: scheme.surfaceContainerHigh,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: .35),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: .6),
            width: .5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: ListView.builder(
            key: const ValueKey('online-gallery-suggestions'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (context, i) {
              final pick = options[i];
              final s = pick.suggestion;
              return GallerySuggestionTile(
                label: s.label,
                term: pick.term,
                color: galleryTagColor(s.category, scheme),
                postCount: s.postCount,
                antecedent: s.antecedent,
                translation: galleryTagTranslatable(s.category)
                    ? s.translation ?? translationOf(s.value)
                    : null,
                highlighted: i == highlighted,
                onTap: () => onSelected(pick),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _platformBar(OnlineGalleryState state) {
    final platforms = state.aiPlatforms;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Text('显示平台  '),
            for (final platform in platforms)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(platform),
                  selected: !state.excludedPlatforms.contains(platform),
                  onSelected: (on) {
                    final excluded = {...state.excludedPlatforms};
                    on ? excluded.remove(platform) : excluded.add(platform);
                    _notifier.setExcludedPlatforms(excluded);
                  },
                  visualDensity: VisualDensity.compact,
                ),
              ),
            TextButton(
              onPressed: () => _notifier.setExcludedPlatforms({}),
              child: const Text('全部平台'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterBar(OnlineGalleryState state, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 7),
      child: Wrap(
        spacing: 7,
        runSpacing: 5,
        children: [
          for (final rating in OnlineGalleryRating.values)
            FilterChip(
              label: Text(rating.label),
              selected: state.ratings.contains(rating.key),
              onSelected: (on) {
                final next = {...state.ratings};
                on ? next.add(rating.key) : next.remove(rating.key);
                _notifier.setRatings(next);
              },
              visualDensity: VisualDensity.compact,
              showCheckmark: false,
            ),
          if (state.feed == OnlineGalleryFeed.ranking) ...[
            for (final period in const [
              ('day', '日榜'),
              ('week', '周榜'),
              ('month', '月榜'),
            ])
              ChoiceChip(
                label: Text(period.$2),
                selected: state.rankingPeriod == period.$1,
                onSelected: (_) => _notifier.setRankingPeriod(period.$1),
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
              ),
          ],
          ActionChip(
            avatar: const Icon(Icons.date_range_outlined, size: 15),
            label: Text(state.dateDays == 0 ? '全部日期' : '近 ${state.dateDays} 天'),
            onPressed: _pickDateFilter,
            visualDensity: VisualDensity.compact,
          ),
          FilterChip(
            label: const Text('过滤水印 / 审核标记'),
            selected: state.outputFilter,
            onSelected: _notifier.setOutputFilter,
            visualDensity: VisualDensity.compact,
            showCheckmark: false,
          ),
          if (state.blacklist.isNotEmpty)
            ActionChip(
              label: Text('黑名单 ${state.blacklist.length}'),
              onPressed: _editBlacklist,
              visualDensity: VisualDensity.compact,
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

  Widget _content(OnlineGalleryState state, ColorScheme scheme) {
    final displayItems = state.displayItems;
    if (state.loading && displayItems.isEmpty && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.items.isEmpty) {
      return _error(state.error!, scheme);
    }
    if (state.source == OnlineGallerySource.aiTag &&
        state.excludesAllAiPlatforms) {
      return _empty('请至少选择一个生成平台', scheme);
    }
    _scheduleLoadMoreCheck();
    if (displayItems.isEmpty) {
      if ((state.outputFilter || state.excludedPlatforms.isNotEmpty) &&
          state.items.isNotEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.filter_alt_off_outlined,
                size: 50,
                color: scheme.outlineVariant,
              ),
              const SizedBox(height: 10),
              const Text('当前筛选没有可显示的图片'),
              const SizedBox(height: 6),
              Text(
                state.loadingMore ? '正在查找后续匹配作品…' : '可调整平台或内容筛选',
                style: context.texts.bodySmall!.copyWith(color: scheme.outline),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  _notifier.setOutputFilter(false);
                  _notifier.setExcludedPlatforms({});
                },
                child: const Text('显示全部结果'),
              ),
            ],
          ),
        );
      }
      return _empty(
        state.feed == OnlineGalleryFeed.favorites ? '还没有收藏作品' : '没有匹配的作品',
        scheme,
      );
    }
    return RefreshIndicator(
      onRefresh: () => _notifier.load(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.maxWidth / 170)
              .floor()
              .clamp(2, 6)
              .toInt();
          final buckets = List.generate(columns, (_) => <OnlineGalleryItem>[]);
          final heights = List<double>.filled(columns, 0);
          for (final item in displayItems) {
            var target = 0;
            for (var i = 1; i < columns; i++) {
              if (heights[i] < heights[target]) target = i;
            }
            buckets[target].add(item);
            // Use source dimensions when available, so portrait posts do not
            // create the large empty row imposed by a fixed GridView tile.
            final ratio = item.aspectRatio.clamp(.3, 3.5).toDouble();
            heights[target] += 1 / ratio + .22;
          }
          return PageStorage(
            bucket: ref.watch(onlineGalleryScrollStorageProvider),
            child: SingleChildScrollView(
              key: PageStorageKey('online-gallery-${state.listRevision}'),
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var column = 0; column < columns; column++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          children: [
                            for (final item in buckets[column]) ...[
                              _OnlineCard(
                                item: item,
                                favorite: state.isFavorite(item),
                                onTap: () => Navigator.of(context).push(
                                  sharedAxisRoute(
                                    OnlineGalleryDetailPage(item: item),
                                  ),
                                ),
                                onFavorite: () =>
                                    _notifier.toggleFavorite(item),
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (state.loadingMore)
                              const SizedBox(
                                height: 120,
                                child: _LoadingTile(),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _empty(String text, ColorScheme scheme) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.public_off_outlined, size: 52, color: scheme.outlineVariant),
        const SizedBox(height: 12),
        Text(
          text,
          style: context.texts.titleSmall!.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '调整来源或搜索条件后重试',
          style: context.texts.bodySmall!.copyWith(color: scheme.outline),
        ),
      ],
    ),
  );

  Widget _error(String error, ColorScheme scheme) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 50, color: scheme.error),
          const SizedBox(height: 12),
          Text(
            '在线画廊暂时不可用',
            style: context.texts.titleSmall!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            error,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => _notifier.load(),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}

class _OnlineCard extends StatelessWidget {
  const _OnlineCard({
    required this.item,
    required this.favorite,
    required this.onTap,
    required this.onFavorite,
  });

  final OnlineGalleryItem item;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final hasDimensions = item.width > 0 && item.height > 0;
    final ratio = hasDimensions
        ? item.aspectRatio.clamp(.3, 3.5).toDouble()
        : .8;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: ratio,
                  child: _RemoteThumb(
                    url: item.previewUrl.isEmpty
                        ? item.imageUrl
                        : item.previewUrl,
                    fit: hasDimensions ? BoxFit.cover : BoxFit.contain,
                  ),
                ),
                Positioned(
                  top: 6,
                  left: 6,
                  child: _RatingBadge(rating: item.rating),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: IconButton(
                    tooltip: favorite ? '取消收藏' : '收藏',
                    onPressed: onFavorite,
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      favorite ? Icons.star : Icons.star_border,
                      color: favorite ? Colors.amber.shade300 : Colors.white,
                      size: 22,
                      shadows: const [
                        Shadow(blurRadius: 3, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (item.source == OnlineGallerySource.aiTag)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: Text(
                  item.platform,
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 5, 7),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.author.isEmpty ? '#${item.id}' : item.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.labelSmall!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${item.score}',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    Icons.favorite,
                    size: 12,
                    color: favorite ? Colors.amber.shade700 : scheme.outline,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteThumb extends StatefulWidget {
  const _RemoteThumb({required this.url, required this.fit, this.fallbackUrl});

  final String url;
  final BoxFit fit;
  final String? fallbackUrl;

  @override
  State<_RemoteThumb> createState() => _RemoteThumbState();
}

class _RemoteThumbState extends State<_RemoteThumb> {
  bool _usingFallback = false;

  @override
  void didUpdateWidget(covariant _RemoteThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.fallbackUrl != widget.fallbackUrl) {
      _usingFallback = false;
    }
  }

  Widget _placeholder(BuildContext context, {required bool broken}) =>
      ColoredBox(
        color: context.scheme.surfaceContainerHigh,
        child: Icon(
          broken ? Icons.broken_image_outlined : Icons.image_outlined,
          color: context.scheme.outline,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final fallback = widget.fallbackUrl;
    final url = _usingFallback && fallback != null ? fallback : widget.url;
    if (url.isEmpty) return _placeholder(context, broken: false);
    return RemoteImage(
      url,
      fit: widget.fit,
      gaplessPlayback: true,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Stack(
          fit: StackFit.expand,
          children: [
            _placeholder(context, broken: false),
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        );
      },
      errorBuilder: (_, _, _) {
        final canFallback =
            !_usingFallback && fallback != null && fallback != url;
        if (canFallback) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_usingFallback) {
              setState(() => _usingFallback = true);
            }
          });
        }
        return _placeholder(context, broken: !canFallback);
      },
    );
  }
}

class _LoadingTile extends StatelessWidget {
  const _LoadingTile();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
  );
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    final color = switch (rating) {
      'g' => FixedSemantic.ok,
      's' => FixedSemantic.warn,
      'q' => Colors.orange,
      _ => context.scheme.error,
    };
    final label = switch (rating) {
      'g' => 'G',
      's' => 'S',
      'q' => 'Q',
      _ => 'E',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class OnlineGalleryDetailPage extends ConsumerStatefulWidget {
  const OnlineGalleryDetailPage({super.key, required this.item});

  final OnlineGalleryItem item;

  @override
  ConsumerState<OnlineGalleryDetailPage> createState() =>
      _OnlineGalleryDetailPageState();
}

class _OnlineGalleryDetailPageState
    extends ConsumerState<OnlineGalleryDetailPage> {
  OnlineGalleryDetail? _detail;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  int _imageIndex = 0;
  OnlineGalleryItem get _item => _detail != null && _detail!.images.isNotEmpty
      ? _detail!.images[_imageIndex.clamp(0, _detail!.images.length - 1)]
      : _detail?.item ?? widget.item;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    final force = _error != null;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final result = await ref
          .read(onlineGalleryProvider.notifier)
          .loadDetail(widget.item, force: force);
      if (result == null) throw const FormatException('详情加载失败');
      if (!mounted) return;
      setState(() {
        _detail = result;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _saveLocal() async {
    if (_saving || (_item.imageUrl.isEmpty && _item.previewUrl.isEmpty)) return;
    setState(() => _saving = true);
    try {
      final url = _item.imageUrl.isEmpty ? _item.previewUrl : _item.imageUrl;
      final bytes = await ref.read(onlineGalleryServiceProvider).download(url);
      final record = await ref
          .read(appStoresProvider)
          .localGallery
          .importBytes(
            bytes,
            '${_item.source.key}_${_item.id}.${_item.fileExtension.isEmpty ? 'jpg' : _item.fileExtension}',
            promptOverride: _item.prompt.isEmpty ? null : _item.prompt,
            negativePromptOverride: _item.negativePrompt.isEmpty
                ? null
                : _item.negativePrompt,
          );
      ref.read(localGalleryProvider.notifier).refreshFromStore();
      if (!mounted) return;
      hintSnack(
        context,
        '已保存到本地图库：${record.name}',
        icon: Icons.check_circle_outline,
      );
    } catch (e) {
      if (mounted) hintSnack(context, '保存失败：$e', icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<Uint8List?> _downloadFullImage() async {
    final url = _item.imageUrl.isEmpty ? _item.previewUrl : _item.imageUrl;
    if (url.isEmpty) return null;
    try {
      return await ref.read(onlineGalleryServiceProvider).download(url);
    } catch (e) {
      if (mounted) hintSnack(context, '图片下载失败：$e', icon: Icons.error_outline);
      return null;
    }
  }

  Future<void> _useAsReference() async {
    final model = ref.read(generateProvider).params.model;
    if (!crSupportsModel(model)) {
      hintSnack(context, '$model 不支持角色参考', icon: Icons.info_outline);
      return;
    }
    final bytes = await _downloadFullImage();
    if (bytes == null || !mounted) return;
    final name = '${_item.source.label}_${_item.id}';
    CharRefEntry? stored;
    try {
      stored = await ref
          .read(charLibraryProvider.notifier)
          .importImageBytes(bytes, name);
    } catch (_) {}
    if (!mounted) return;
    ref
        .read(generateProvider.notifier)
        .addCharRef(image: bytes, name: name, imageHash: stored?.id);
    _openGeneration();
  }

  Future<void> _useAsImg2Img() async {
    final bytes = await _downloadFullImage();
    if (bytes == null || !mounted) return;
    try {
      final (width, height) = await decodeImageSize(bytes);
      final size = img2imgResolution(width, height);
      ref
          .read(generateProvider.notifier)
          .setImg2ImgImage(image: bytes, width: size.w, height: size.h);
      _openGeneration();
    } catch (_) {
      if (mounted) hintSnack(context, '无法读取图片尺寸', icon: Icons.error_outline);
    }
  }

  void _openGeneration() {
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
    // Both the detail and gallery routes sit above the shell.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  String _promptCandidate() {
    final prompt = _item.prompt.trim();
    if (prompt.isNotEmpty) return prompt;

    return _item.source == OnlineGallerySource.aiTag
        ? ''
        : _item.tags.join(', ');
  }

  Future<void> _savePromptToLibrary() async {
    final galleryState = ref.read(onlineGalleryProvider);
    final text = galleryState.filterOutputPrompt(_promptCandidate());
    if (text.isEmpty) {
      hintSnack(context, '这张作品没有可保存的提示词', icon: Icons.info_outline);
      return;
    }
    final saved = await savePromptToTagLibrary(
      context,
      ref,
      prompt: text,
      negative: _item.negativePrompt,
      suggestedName: '${_item.source.label} ${_item.id}',
    );
    if (saved && mounted) {
      hintSnack(context, '已保存到词库', icon: Icons.bookmark_added_outlined);
    }
  }

  Future<void> _usePrompt() async {
    final selection = await showModalBottomSheet<GalleryPromptImport>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => OnlineGalleryImportSheet(
        item: _item,
        naiTarget:
            providerOfModel(ref.read(generateProvider).params.model) ==
            GenProvider.nai,
        filter: ref.read(onlineGalleryProvider).filterOutputPrompt,
      ),
    );
    if (selection == null || !mounted) return;
    ref
        .read(generateProvider.notifier)
        .setPrompts(positive: selection.positive, negative: selection.negative);
    _openGeneration();
  }

  /// 宽屏(iPad 横竖屏、大屏)左图右栏;窄屏图在上、操作吸底。
  static const _wideBreakpoint = 840.0;

  void _searchTag(String tag) {
    final current = ref.read(onlineGalleryProvider).query;
    final next = current.trim().isEmpty ? tag : '$current $tag';
    ref.read(onlineGalleryProvider.notifier).setQuery(next);
    unawaited(ref.read(onlineGalleryProvider.notifier).load());
    Navigator.pop(context);
  }

  void _copyTag(String tag) {
    final text = tag.replaceAll('_', ' ');
    Clipboard.setData(ClipboardData(text: text));
    hintSnack(context, '已复制:$text', icon: Icons.copy_rounded);
  }

  void _openViewer(OnlineGalleryItem item) {
    final preview = item.previewUrl.isEmpty ? item.imageUrl : item.previewUrl;
    final full = item.imageUrl.isEmpty ? preview : item.imageUrl;
    if (full.isEmpty) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: Motion.medium,
        reverseTransitionDuration: Motion.fast,
        pageBuilder: (_, _, _) => _OnlineImageViewer(
          full: full,
          preview: preview,
          sourceWidth: item.width,
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onlineGalleryProvider);
    final favorite = state.isFavorite(_item);
    final scheme = context.scheme;
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_item.source.label} · ${_item.id}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: favorite ? '取消收藏' : '收藏',
            icon: Icon(favorite ? Icons.star : Icons.star_border),
            onPressed: () =>
                ref.read(onlineGalleryProvider.notifier).toggleFavorite(_item),
          ),
          const SizedBox(width: 4),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : SafeArea(
              key: const ValueKey('online-gallery-detail-actions'),
              child: _actions(scheme),
            ),
      // Keep the list rendition visible while metadata is fetched. Previously
      // the whole body was replaced by a spinner/error, which made a tap look
      // like an empty black page when a source detail endpoint was slow or
      // blocked.
      body: wide ? _wideBody(scheme) : _narrowBody(scheme),
    );
  }

  /// 操作区:主操作「使用提示词」占满一行,其余四个并排成图标 + 字的小格。
  Widget _actions(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          height: 46,
          child: FilledButton.icon(
            onPressed: _loading ? null : _usePrompt,
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('使用提示词'),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                icon: Icons.save_alt,
                label: '保存本地',
                busy: _saving,
                onTap: _saving ? null : _saveLocal,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionTile(
                icon: Icons.center_focus_strong,
                label: '用作参考',
                onTap: _saving ? null : _useAsReference,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionTile(
                icon: Icons.image_search_outlined,
                label: '图生图',
                onTap: _saving ? null : _useAsImg2Img,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionTile(
                icon: Icons.bookmark_add_outlined,
                label: '存到词库',
                onTap: _savePromptToLibrary,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _wideBody(ColorScheme scheme) {
    final width = MediaQuery.sizeOf(context).width;
    final panel = (width * .32).clamp(360.0, 440.0);
    return Column(
      children: [
        SizedBox(
          height: 2,
          child: _loading ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _stage()),
              SizedBox(
                width: panel,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: .6),
                        width: .5,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                          children: _info(scheme),
                        ),
                      ),
                      SafeArea(
                        key: const ValueKey('online-gallery-detail-actions'),
                        top: false,
                        left: false,
                        child: _actions(scheme),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 宽屏左侧的看图区:整张图按比例放进可用空间,多图时下面是切换。
  Widget _stage() {
    final images = _detail?.images ?? const <OnlineGalleryItem>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        children: [
          Expanded(child: Center(child: _image(_item))),
          if (images.length > 1) ...[
            const SizedBox(height: 12),
            _imagePicker(images),
          ],
        ],
      ),
    );
  }

  Widget _narrowBody(ColorScheme scheme) {
    final images = _detail?.images ?? const <OnlineGalleryItem>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        // 竖长图别把下面的信息整屏挤走
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .6,
            ),
            child: _image(_item),
          ),
        ),
        if (images.length > 1) ...[
          const SizedBox(height: 10),
          _imagePicker(images),
        ],
        const SizedBox(height: 18),
        ..._info(scheme),
      ],
    );
  }

  Widget _image(OnlineGalleryItem item) => AspectRatio(
    key: const ValueKey('online-gallery-detail-image'),
    aspectRatio: item.aspectRatio.clamp(.3, 3.5).toDouble(),
    child: GestureDetector(
      onTap: () => _openViewer(item),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: _RemoteThumb(
          // Load the large preview first. Full originals can be very large
          // or hotlink-protected; actions still download imageUrl, and the
          // full-screen viewer swaps the original in once it arrives.
          url: item.previewUrl.isEmpty ? item.imageUrl : item.previewUrl,
          fit: BoxFit.contain,
          fallbackUrl: item.imageUrl,
        ),
      ),
    ),
  );

  Widget _imagePicker(List<OnlineGalleryItem> images) => Wrap(
    spacing: 6,
    runSpacing: 6,
    alignment: WrapAlignment.center,
    children: [
      for (var i = 0; i < images.length; i++)
        ChoiceChip(
          label: Text('图片 ${i + 1}'),
          selected: _imageIndex == i,
          onSelected: (_) => setState(() => _imageIndex = i),
        ),
    ],
  );

  List<Widget> _info(ColorScheme scheme) {
    final item = _item;
    final rating = OnlineGalleryRatingX.fromKey(item.rating);
    final created = item.createdAt?.toLocal();
    return [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Material(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(10),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.info_outline, color: scheme.onErrorContainer),
              title: Text(
                '详情暂时不可用，先显示预览图',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
              trailing: TextButton(
                onPressed: _loadDetail,
                child: Text(
                  '重试',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ),
          ),
        ),
      if (item.title.isNotEmpty) ...[
        Text(
          item.title,
          style: context.texts.titleMedium!.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 14),
      ],
      Wrap(
        spacing: 22,
        runSpacing: 12,
        children: [
          _Spec(label: '来源', value: item.source.label),
          if (item.source == OnlineGallerySource.aiTag)
            _Spec(label: '生成平台', value: item.platform),
          if (rating != null) _Spec(label: '分级', value: rating.label),
          _Spec(label: '评分', value: '${item.score}'),
          if (item.width > 0)
            _Spec(label: '尺寸', value: '${item.width} × ${item.height}'),
          if (item.author.isNotEmpty) _Spec(label: '作者', value: item.author),
          if (created != null)
            _Spec(
              label: '发布',
              value:
                  '${created.year}-${'${created.month}'.padLeft(2, '0')}-${'${created.day}'.padLeft(2, '0')}',
            ),
        ],
      ),
      if (item.description.isNotEmpty) ...[
        const SizedBox(height: 18),
        _TextSection(title: '简介', text: item.description),
      ],
      if (item.prompt.isNotEmpty) ...[
        const SizedBox(height: 18),
        _TextSection(
          title: '正向提示词',
          text: item.prompt,
          source: item.promptSource,
        ),
      ],
      if (item.negativePrompt.isNotEmpty) ...[
        const SizedBox(height: 14),
        _TextSection(
          title: '负向提示词',
          text: item.negativePrompt,
          source: item.negativePromptSource,
        ),
      ],
      if (!_loading &&
          item.source == OnlineGallerySource.aiTag &&
          item.prompt.isEmpty &&
          item.negativePrompt.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 14),
          child: Text('这张图没有可解析的生图提示词；作品标签不会作为提示词导入。'),
        ),
      if (item.tags.isNotEmpty) ...[
        const SizedBox(height: 22),
        _tags(item, scheme),
      ],
    ];
  }

  Widget _tags(OnlineGalleryItem item, ColorScheme scheme) {
    final groups = item.groupedTags;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              item.source == OnlineGallerySource.aiTag ? '作品标签' : '标签',
              style: context.texts.titleSmall!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${item.tags.length}',
              style: context.texts.labelMedium!.copyWith(color: scheme.outline),
            ),
            const Spacer(),
            Text(
              '点按搜索 · 长按复制',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ],
        ),
        if (item.source == OnlineGallerySource.aiTag)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '作品标签不是生图提示词',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ),
        GalleryTagTranslations(
          tags: [
            for (final g in groups.entries)
              if (galleryTagTranslatable(g.key)) ...g.value,
          ],
          builder: (context, tr) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final group in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 14, bottom: 7),
                  child: Text(
                    '${group.key.label} · ${group.value.length}',
                    style: context.texts.labelMedium!.copyWith(
                      color: galleryTagColor(group.key, scheme),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in group.value)
                      GalleryTagChip(
                        tag: tag,
                        color: galleryTagColor(group.key, scheme),
                        reserveTrans: galleryTagTranslatable(group.key),
                        trans: galleryTagTranslatable(group.key)
                            ? tr.of(tag)
                            : null,
                        pending:
                            galleryTagTranslatable(group.key) &&
                            tr.pending(tag),
                        onTap: () => _searchTag(tag),
                        onLongPress: () => _copyTag(tag),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 操作区的小格:图标在上、字在下,和主按钮同一套圆角。
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final enabled = onTap != null;
    final fg = enabled ? scheme.onSurface : scheme.outline;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 20,
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(2),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, size: 20, color: fg),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.labelMedium!.copyWith(color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 详情信息的一项:上面小字标签,下面数值。
class _Spec extends StatelessWidget {
  const _Spec({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 220),
    child: Column(
      mainAxisSize: MainAxisSize.min,
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
          style: context.texts.bodyMedium!.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// 点图进来的全屏看图:双指缩放,原图到货前先垫着预览图。
class _OnlineImageViewer extends StatelessWidget {
  const _OnlineImageViewer({
    required this.full,
    required this.preview,
    required this.sourceWidth,
  });

  final String full;
  final String preview;
  final int sourceWidth;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget previewImage() => preview.isEmpty
        ? const SizedBox.shrink()
        : RemoteImage(preview, fit: BoxFit.contain, gaplessPlayback: true);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: RemoteImage(
                  full,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  // 按原图宽解码,放大看得清;不知道宽就给个够用的上限
                  decodeWidth: (sourceWidth > 0 ? sourceWidth : 4096) / dpr,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            previewImage(),
                            const Align(
                              alignment: Alignment.bottomCenter,
                              child: Padding(
                                padding: EdgeInsets.only(bottom: 32),
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                  errorBuilder: (_, _, _) => previewImage(),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  tooltip: '关闭',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: .12),
                  ),
                  color: Colors.white,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextSection extends StatelessWidget {
  const _TextSection({
    required this.title,
    required this.text,
    this.source = '',
  });

  final String title;
  final String text;
  final String source;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700),
      ),
      if (source.isNotEmpty)
        Text('来源：$source', style: context.texts.labelSmall),
      const SizedBox(height: 7),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: context.scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          text,
          style: context.texts.bodySmall!.copyWith(height: 1.55),
        ),
      ),
    ],
  );
}

IconData _ratingIcon(OnlineGalleryRating rating) => switch (rating) {
  OnlineGalleryRating.general => Icons.check_circle_outline,
  OnlineGalleryRating.sensitive => Icons.warning_amber_outlined,
  OnlineGalleryRating.questionable => Icons.help_outline,
  OnlineGalleryRating.explicit => Icons.no_adult_content,
};
