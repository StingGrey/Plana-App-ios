import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/net/remote_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/image_ops.dart' show decodeImageSize, img2imgResolution;
import '../generate/generate_state.dart';
import '../generate/models.dart' show crSupportsModel;
import '../generate/widgets/common.dart' show hintSnack, sharedAxisRoute;
import '../char_library/char_library.dart';
import '../local_gallery/local_gallery_state.dart';
import '../shell/shell_state.dart';
import '../inspiration/codex/codex_view.dart';
import '../inspiration/prompt_library_save.dart';
import 'online_gallery_models.dart';
import 'online_gallery_service.dart';

/// Multi-source online reference gallery.
class OnlineGalleryPage extends ConsumerStatefulWidget {
  const OnlineGalleryPage({super.key});

  @override
  ConsumerState<OnlineGalleryPage> createState() => _OnlineGalleryPageState();
}

class _OnlineGalleryPageState extends ConsumerState<OnlineGalleryPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  bool _showFilters = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  OnlineGalleryNotifier get _notifier => ref.read(onlineGalleryProvider.notifier);

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 700) {
      final state = ref.read(onlineGalleryProvider);
      if (state.hasMore && !state.loading && !state.loadingMore) {
        _notifier.load(append: true);
      }
    }
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('应用')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    final tags = value
        .split(RegExp(r'[\n,，\s]+'))
        .map((tag) => tag.trim().toLowerCase().replaceAll(' ', '_'))
        .where((tag) => tag.isNotEmpty && !tag.contains(':') && !tag.contains('*'))
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
                    on == true ? selected.add(rating.key) : selected.remove(rating.key);
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
    final scheme = context.scheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('在线画廊'),
        actions: [
          IconButton(
            tooltip: '黑名单',
            icon: Icon(
              state.blacklist.isEmpty ? Icons.block_outlined : Icons.block,
              color: state.blacklist.isEmpty ? null : scheme.error,
            ),
            onPressed: _editBlacklist,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: state.loading ? null : () => _notifier.load(),
          ),
        ],
      ),
      body: Column(
        children: [
          _sourceBar(state, scheme),
          if (state.source == OnlineGallerySource.codex)
            const Expanded(child: CodexView())
          else ...[
            _feedBar(state, scheme),
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
      ),
    );
  }

  Widget _sourceBar(OnlineGalleryState state, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
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
                        Icon(source == state.source ? Icons.check : Icons.public, size: 18),
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
                    Expanded(child: Text(state.source.label, style: context.texts.bodyMedium!.copyWith(fontWeight: FontWeight.w700))),
                    Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
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
              onSelectionChanged: (selection) => _notifier.setFeed(selection.first),
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
              color: state.ratings.length < 4 ? scheme.primary : scheme.onSurfaceVariant,
            ),
            onPressed: _pickRatings,
          ),
        ],
      ),
    );
  }

  Widget _searchBar(OnlineGalleryState state, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: TextField(
        controller: _search,
        onChanged: _onSearchChanged,
        onSubmitted: (value) {
          _debounce?.cancel();
          _notifier.setQuery(value);
          _notifier.load();
        },
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: state.feed == OnlineGalleryFeed.ranking ? '搜索排行标签…' : '搜索标签…',
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.blacklist.isNotEmpty)
                Icon(Icons.block, size: 17, color: scheme.error),
              IconButton(
                tooltip: _showFilters ? '收起筛选' : '展开筛选',
                icon: Icon(_showFilters ? Icons.expand_less : Icons.expand_more),
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
                  days == 0
                      ? '全部日期'
                      : (days == 1 ? '今天' : '近 $days 天'),
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
    if (displayItems.isEmpty) {
      if (state.outputFilter && state.items.isNotEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.filter_alt_off_outlined, size: 50, color: scheme.outlineVariant),
              const SizedBox(height: 10),
              const Text('当前筛选没有可显示的图片'),
              const SizedBox(height: 6),
              Text(
                '部分来源需要打开详情后才会提供完整元数据',
                style: context.texts.bodySmall!.copyWith(color: scheme.outline),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _notifier.setOutputFilter(false),
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
          final columns = (constraints.maxWidth / 170).floor().clamp(2, 6).toInt();
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
          return SingleChildScrollView(
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
                                sharedAxisRoute(OnlineGalleryDetailPage(item: item)),
                              ),
                              onFavorite: () => _notifier.toggleFavorite(item),
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
        Text(text, style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text('调整来源或搜索条件后重试', style: context.texts.bodySmall!.copyWith(color: scheme.outline)),
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
          Text('在线画廊暂时不可用', style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(error, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.texts.bodySmall!.copyWith(color: scheme.outline)),
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: () => _notifier.load(), icon: const Icon(Icons.refresh), label: const Text('重试')),
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
    final ratio = hasDimensions ? item.aspectRatio.clamp(.3, 3.5).toDouble() : .8;
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
                    url: item.previewUrl.isEmpty ? item.imageUrl : item.previewUrl,
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
                      shadows: const [Shadow(blurRadius: 3, color: Colors.black54)],
                    ),
                  ),
                ),
              ],
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
                      style: context.texts.labelSmall!.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '${item.score}',
                    style: context.texts.labelSmall!.copyWith(color: scheme.outline),
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
  const _RemoteThumb({
    required this.url,
    required this.fit,
    this.fallbackUrl,
  });

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

  Widget _placeholder(BuildContext context, {required bool broken}) => ColoredBox(
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
    final color = switch (rating) {'g' => FixedSemantic.ok, 's' => FixedSemantic.warn, 'q' => Colors.orange, _ => context.scheme.error};
    final label = switch (rating) {'g' => 'G', 's' => 'S', 'q' => 'Q', _ => 'E'};
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: .92), borderRadius: BorderRadius.circular(5)),
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
    );
  }
}

class OnlineGalleryDetailPage extends ConsumerStatefulWidget {
  const OnlineGalleryDetailPage({super.key, required this.item});

  final OnlineGalleryItem item;

  @override
  ConsumerState<OnlineGalleryDetailPage> createState() => _OnlineGalleryDetailPageState();
}

class _OnlineGalleryDetailPageState extends ConsumerState<OnlineGalleryDetailPage> {
  OnlineGalleryDetail? _detail;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  OnlineGalleryItem get _item => _detail?.item ?? widget.item;

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
      final result = await ref.read(onlineGalleryProvider.notifier).loadDetail(
        widget.item,
        force: force,
      );
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
      final record = await ref.read(appStoresProvider).localGallery.importBytes(
        bytes,
        '${_item.source.key}_${_item.id}.${_item.fileExtension.isEmpty ? 'jpg' : _item.fileExtension}',
        promptOverride: _item.prompt.isEmpty ? null : _item.prompt,
        negativePromptOverride:
            _item.negativePrompt.isEmpty ? null : _item.negativePrompt,
      );
      ref.read(localGalleryProvider.notifier).refreshFromStore();
      if (!mounted) return;
      hintSnack(context, '已保存到本地图库：${record.name}', icon: Icons.check_circle_outline);
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
    ref.read(generateProvider.notifier).addCharRef(
      image: bytes,
      name: name,
      imageHash: stored?.id,
    );
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
    Navigator.of(context).pop();
  }

  Future<void> _useAsImg2Img() async {
    final bytes = await _downloadFullImage();
    if (bytes == null || !mounted) return;
    try {
      final (width, height) = await decodeImageSize(bytes);
      final size = img2imgResolution(width, height);
      ref.read(generateProvider.notifier).setImg2ImgImage(
        image: bytes,
        width: size.w,
        height: size.h,
      );
      ref.read(shellIndexProvider.notifier).select(kTabCreate);
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) hintSnack(context, '无法读取图片尺寸', icon: Icons.error_outline);
    }
  }

  Future<void> _savePromptToLibrary() async {
    final galleryState = ref.read(onlineGalleryProvider);
    final raw = _item.prompt.trim().isNotEmpty
        ? _item.prompt.trim()
        : (_detail?.description.trim() ?? '');
    final text = galleryState.filterOutputPrompt(raw);
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
    final galleryState = ref.read(onlineGalleryProvider);
    final rawPrompt = _item.prompt.trim().isNotEmpty
        ? _item.prompt.trim()
        : (_detail?.raw['prompt']?.toString().trim() ?? '');
    final description = _detail?.description.trim() ?? _item.description.trim();
    final text = rawPrompt.isNotEmpty
        ? galleryState.filterOutputPrompt(rawPrompt)
        : (description.isNotEmpty ? description : _item.tags.join(', '));
    if (text.isEmpty) {
      hintSnack(context, '这张作品没有可用的提示词', icon: Icons.info_outline);
      return;
    }
    ref.read(generateProvider.notifier).setPrompts(positive: text);
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onlineGalleryProvider);
    final favorite = state.isFavorite(_item);
    final scheme = context.scheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('${_item.source.label} · ${_item.id}', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: favorite ? '取消收藏' : '收藏',
            icon: Icon(favorite ? Icons.star : Icons.star_border),
            onPressed: () => ref.read(onlineGalleryProvider.notifier).toggleFavorite(_item),
          ),
          IconButton(
            tooltip: '保存到本地图库',
            icon: _saving ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download_outlined),
            onPressed: _saving ? null : _saveLocal,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _usePrompt,
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('使用提示词'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _saveLocal,
                      icon: const Icon(Icons.save_alt, size: 18),
                      label: const Text('保存本地'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _saving ? null : _useAsReference,
                      icon: const Icon(Icons.center_focus_strong, size: 18),
                      label: const Text('用作参考'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _saving ? null : _useAsImg2Img,
                      icon: const Icon(Icons.image_search_outlined, size: 18),
                      label: const Text('图生图'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _savePromptToLibrary,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  label: const Text('保存提示词到词库'),
                ),
              ),
            ],
          ),
        ),
      ),
      // Keep the list rendition visible while metadata is fetched. Previously
      // the whole body was replaced by a spinner/error, which made a tap look
      // like an empty black page when a source detail endpoint was slow or
      // blocked.
      body: _body(scheme),
    );
  }

  Widget _body(ColorScheme scheme) {
    final item = _item;
    final imageRatio = item.aspectRatio.clamp(.3, 3.5).toDouble();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
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
                  child: Text('重试', style: TextStyle(color: scheme.onErrorContainer)),
                ),
              ),
            ),
          ),
        AspectRatio(
          aspectRatio: imageRatio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _RemoteThumb(
              url: item.imageUrl.isEmpty ? item.previewUrl : item.imageUrl,
              fit: BoxFit.contain,
              fallbackUrl: item.previewUrl,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            _DetailChip(label: '来源', value: item.source.label),
            _DetailChip(label: '评分', value: '${item.score}'),
            if (item.width > 0) _DetailChip(label: '尺寸', value: '${item.width} × ${item.height}'),
            if (item.author.isNotEmpty) _DetailChip(label: '作者', value: item.author),
          ],
        ),
        if (item.title.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(item.title, style: context.texts.titleMedium!.copyWith(fontWeight: FontWeight.w700)),
        ],
        if (item.description.isNotEmpty) ...[
          const SizedBox(height: 14),
          _TextSection(title: '简介', text: item.description),
        ],
        if (item.prompt.isNotEmpty) ...[
          const SizedBox(height: 14),
          _TextSection(title: '正向提示词', text: item.prompt),
        ],
        if (item.negativePrompt.isNotEmpty) ...[
          const SizedBox(height: 14),
          _TextSection(title: '负向提示词', text: item.negativePrompt),
        ],
        if (item.tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('标签 (${item.tags.length})', style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 7),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in item.tags.take(160))
                InputChip(
                  label: Text(tag, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onPressed: () {
                    final current = ref.read(onlineGalleryProvider).query;
                    final next = current.trim().isEmpty ? tag : '$current $tag';
                    ref.read(onlineGalleryProvider.notifier).setQuery(next);
                    Navigator.pop(context);
                  },
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ],
    );
  }

}

class _DetailChip extends StatelessWidget {
  const _DetailChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
    decoration: BoxDecoration(
      color: context.scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    child: RichText(
      text: TextSpan(
        style: context.texts.labelMedium,
        children: [
          TextSpan(text: '$label  ', style: TextStyle(color: context.scheme.outline)),
          TextSpan(text: value, style: TextStyle(color: context.scheme.onSurface, fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}

class _TextSection extends StatelessWidget {
  const _TextSection({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 7),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: context.scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(text, style: context.texts.bodySmall!.copyWith(height: 1.55)),
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
