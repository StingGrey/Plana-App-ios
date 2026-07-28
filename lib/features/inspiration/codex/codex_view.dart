import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import 'codex_models.dart';
import 'codex_providers.dart';
import 'codex_sheets.dart';

/// 法典浏览器:灵感页选中「法典」分类时的正文。
/// 顶部选法典 + 来源;下面搜索 + 顶级分类筛选 + 双列瀑布流。只读,点词条看详情。
class CodexView extends ConsumerStatefulWidget {
  const CodexView({super.key});

  @override
  ConsumerState<CodexView> createState() => _CodexViewState();
}

const _edge = 14.0;
const _gap = 10.0;

class _CodexViewState extends ConsumerState<CodexView> {
  String _search = '';
  List<String> _catPath = const []; // 分类树选中路径(空=全部;前缀匹配词条 path)
  Timer? _debounce;
  bool _introScheduled = false; // 首次说明弹窗本会话是否已排期(防重复弹)
  final _scroll = ScrollController();

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    // 上万词条,逐键过滤会卡;250ms 防抖
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _search = v);
    });
  }

  String _resolveSelectedId(List<CodexMeta> index) =>
      resolveSelectedCodex(index, ref.watch(selectedCodexProvider)).id;

  List<CodexEntry> _filtered(CodexData d) {
    final q = _search.trim().toLowerCase();
    return [
      for (final e in d.entries)
        if (_underCat(e) &&
            (q.isEmpty ||
                e.title.toLowerCase().contains(q) ||
                e.tags.toLowerCase().contains(q)))
          e,
    ];
  }

  bool _underCat(CodexEntry e) => codexPathUnder(e.path, _catPath);

  @override
  Widget build(BuildContext context) {
    // 换法典后重置分类筛选。选择器已挪到外层顶栏,靠 provider 联动重置。
    ref.listen(selectedCodexProvider, (_, _) {
      if (mounted) setState(() => _catPath = const []);
    });
    final indexAsync = ref.watch(codexIndexProvider);
    return indexAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          _error('法典索引加载失败', () => ref.invalidate(codexIndexProvider)),
      data: (index) {
        if (index.isEmpty) return _msg('暂无法典');
        final selId = _resolveSelectedId(index);
        final meta = index.firstWhere((m) => m.id == selId);
        // 首次进入法典功能:读盘确认为「没读过」时弹一次说明。
        if (ref.watch(codexIntroProvider) == false) _maybeShowIntro(meta);
        return _body(index, meta);
      },
    );
  }

  /// 首次进入弹一次说明(post-frame 起弹,防重入)。
  void _maybeShowIntro(CodexMeta meta) {
    if (_introScheduled) return;
    _introScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showIntroDialog(meta);
    });
  }

  void _showIntroDialog(CodexMeta meta) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.menu_book_outlined, color: context.scheme.primary),
        title: const Text('法典图鉴'),
        content: SelectableText(
          '数据源来自 https://novelai.quicktagcloud.com/\n\n'
          '(正式发布前会补齐所有作者出处)',
          style: context.texts.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(codexIntroProvider.notifier).ack();
              Navigator.pop(ctx);
              showCodexAboutSheet(context, meta);
            },
            child: const Text('来源与致谢'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(codexIntroProvider.notifier).ack();
              Navigator.pop(ctx);
            },
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  Widget _body(List<CodexMeta> index, CodexMeta meta) {
    final dataAsync = ref.watch(codexDataProvider(meta.id));
    return dataAsync.when(
      loading: () => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              '正在载入 ${meta.entryCount} 条词条…',
              style: context.texts.bodySmall!.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      error: (e, _) =>
          _error('法典加载失败', () => ref.invalidate(codexDataProvider(meta.id))),
      data: (d) {
        final media =
            ref.watch(codexMediaProvider).value ?? CodexMedia.fallback;
        final entries = _filtered(d);
        return Column(
          children: [
            _searchRow(),
            _filterBar(d, meta, media, entries),
            Expanded(
              child: entries.isEmpty
                  ? _msg(_search.isNotEmpty ? '没有匹配的词条' : '暂无词条')
                  : _grid(meta, media, entries),
            ),
          ],
        );
      },
    );
  }

  Widget _searchRow() {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_edge, 8, _edge, 0),
      child: TextField(
        onChanged: _onSearch,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索标题 / 提示词…',
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
    );
  }

  /// 筛选行:分类树入口(全部分类栏)+ 右侧随机按钮。上下外边距相等。
  /// 分类按钮用 Expanded 占左、随机按钮自然宽靠右——单个 Expanded 吸掉所有
  /// 余量,随机才会真正贴右(Flexible + Spacer 双 flex 会把余量甩到行尾)。
  Widget _filterBar(
    CodexData d,
    CodexMeta meta,
    CodexMedia media,
    List<CodexEntry> entries,
  ) {
    final tree = d.effectiveTree;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_edge, 8, _edge, 8),
      child: Row(
        children: [
          Expanded(
            child: tree.isNotEmpty
                ? Align(alignment: Alignment.centerLeft, child: _catButton(d))
                : const SizedBox.shrink(),
          ),
          _randomButton(meta, media, entries),
        ],
      ),
    );
  }

  /// 分类胶囊:点开层级树选;已选时显示末级名 + 清除叉,主色实底标记。
  Widget _catButton(CodexData d) {
    final scheme = context.scheme;
    final on = _catPath.isNotEmpty;
    final label = on ? _catPath.last : '全部分类';
    return Material(
      color: on ? scheme.primary : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          final picked = await showCodexCategorySheet(
            context,
            d.effectiveTree,
            _catPath,
            d.entries.length,
          );
          if (picked != null && mounted) setState(() => _catPath = picked);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 15,
                color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.labelMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                    color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (on)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _catPath = const []),
                  child: Icon(Icons.close, size: 16, color: scheme.onPrimary),
                )
              else
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 随机按钮:从当前筛选出的词条里随机抽一条,弹详情并可「继续抽」。
  Widget _randomButton(
    CodexMeta meta,
    CodexMedia media,
    List<CodexEntry> entries,
  ) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (entries.isEmpty) {
            hintSnack(context, '当前没有可抽的词条', icon: Icons.casino_outlined);
            return;
          }
          showCodexRandomSheet(context, meta, media, entries);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.casino_outlined,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '随机',
                style: context.texts.labelMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grid(CodexMeta meta, CodexMedia media, List<CodexEntry> entries) {
    final w = MediaQuery.sizeOf(context).width;
    final colW = (w - _edge * 2 - _gap) / 2;
    final (left, right) = _splitColumns(entries, colW);
    return CustomScrollView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverCrossAxisGroup(
          slivers: [
            _column(
              meta,
              media,
              entries,
              left,
              leftPad: _edge,
              rightPad: _gap / 2,
            ),
            _column(
              meta,
              media,
              entries,
              right,
              leftPad: _gap / 2,
              rightPad: _edge,
            ),
          ],
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }

  /// [all] = 当前筛选出的整批(详情页左右滑动就在这批里翻);
  /// [items] = 本列分到的那部分。
  Widget _column(
    CodexMeta meta,
    CodexMedia media,
    List<CodexEntry> all,
    List<CodexEntry> items, {
    required double leftPad,
    required double rightPad,
  }) {
    return SliverPadding(
      padding: EdgeInsets.only(left: leftPad, right: rightPad, top: 6),
      sliver: SliverList.builder(
        itemCount: items.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(bottom: _gap),
          child: _CodexCard(
            codex: meta,
            entry: items[i],
            media: media,
            onTap: () {
              // 瀑布流按列拆过,序号要回到整批里取(左右翻按筛选后的原始顺序)
              final idx = all.indexWhere((x) => x.id == items[i].id);
              if (idx < 0) return;
              showCodexDetailSheet(
                context,
                meta,
                media,
                entries: all,
                index: idx,
              );
            },
          ),
        ),
      ),
    );
  }

  /// 双列瀑布流:按估算高度贪心塞进较矮的一列(用 aspect + 标题条估高)。
  (List<CodexEntry>, List<CodexEntry>) _splitColumns(
    List<CodexEntry> items,
    double colW,
  ) {
    final left = <CodexEntry>[], right = <CodexEntry>[];
    var lh = 0.0, rh = 0.0;
    for (final e in items) {
      final h = colW / (e.aspect <= 0 ? 0.75 : e.aspect) + 40;
      if (lh <= rh) {
        left.add(e);
        lh += h;
      } else {
        right.add(e);
        rh += h;
      }
    }
    return (left, right);
  }

  Widget _error(String text, VoidCallback onRetry) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 44,
            color: scheme.outlineVariant,
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _msg(String text) {
    final scheme = context.scheme;
    return Center(
      child: Text(
        text,
        style: context.texts.bodyMedium!.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

Widget _miniTag(BuildContext context, String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .16),
    borderRadius: BorderRadius.circular(6),
  ),
  child: Text(
    label,
    style: context.texts.labelSmall!.copyWith(
      color: color,
      fontWeight: FontWeight.w700,
    ),
  ),
);

/// 解析当前应显示的法典:选过就用选中项,否则取索引首个非 R18(退而取首个)。
CodexMeta resolveSelectedCodex(List<CodexMeta> index, String? sel) {
  if (sel != null) {
    for (final m in index) {
      if (m.id == sel) return m;
    }
  }
  final sfw = index.where((m) => !m.nsfw);
  return sfw.isNotEmpty ? sfw.first : index.first;
}

/// 「选择主法典」按钮:显示当前法典标题,点开选择器换法典。
/// 放在灵感页法典模式顶栏右侧的空位,替代原 CodexView 头部整行。
/// 换法典只改 [selectedCodexProvider],正文的分类筛选由 CodexView 监听联动重置。
class CodexPickerButton extends ConsumerWidget {
  const CodexPickerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final index = ref.watch(codexIndexProvider).value;
    if (index == null || index.isEmpty) return const SizedBox(height: 44);
    final meta = resolveSelectedCodex(index, ref.watch(selectedCodexProvider));
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          final id = await showCodexPickerSheet(context, index, meta.id);
          if (id != null) {
            ref.read(selectedCodexProvider.notifier).select(id);
          }
        },
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  meta.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.titleSmall!.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (meta.nsfw) ...[
                const SizedBox(width: 6),
                _miniTag(context, 'R18', scheme.error),
              ],
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_down,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 瀑布流卡:例图(cover)+ 底部渐变标题;无图退成配色块 + 居中标题。
class _CodexCard extends StatelessWidget {
  const _CodexCard({
    required this.codex,
    required this.entry,
    required this.media,
    required this.onTap,
  });

  final CodexMeta codex;
  final CodexEntry entry;
  final CodexMedia media;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final url = codexImageUrl(codex, entry, media);
    final aspect = entry.aspect <= 0 ? 0.75 : entry.aspect;
    return Material(
      color: scheme.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: aspect,
              child: url == null
                  ? _placeholder(context)
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      frameBuilder: codexFadeIn,
                      errorBuilder: (_, _, _) => _placeholder(context),
                    ),
            ),
            if (url != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 16, 10, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: .66),
                      ],
                    ),
                  ),
                  child: Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            if (entry.isNew)
              Positioned(
                left: 7,
                top: 7,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.tertiary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'NEW',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.onTertiary,
                      fontWeight: FontWeight.w800,
                      fontSize: 9,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final scheme = context.scheme;
    return ColoredBox(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Text(
            entry.title,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
