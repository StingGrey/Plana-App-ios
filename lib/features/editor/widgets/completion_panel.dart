import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../data/suggestions.dart';
import '../data/tag_completion.dart';
import 'completion_bar.dart' show CompletionGrip, suggestionGlyph;

/// 形态 B · 展开态:分类竖向列表(键盘收起,腾出纵向空间)。
/// 由形态 A 上滑 / 点抓手进入;顶部抓手或下滑 / 底部提示 → 收起回形态 A。
///
/// 结构(只借设计稿布局,图标与配色沿用现有 [suggestionGlyph] + M3 语义色):
/// - 抓手 + 头部(`补全结果` · 项数 · 热度/字母排序切换)
/// - 分节:画师 / 角色 / 我的 OC / 作品 / 标签,各带彩色图标 + 计数 + 细分隔线,节标题点按折叠
/// - 每行:名 + 译文/来源 · 热度 · 👁 预览(作品行为骰子随机抽取)· `+` 连续插入
/// - 👁 只给标签 / 角色:画师串与 OC 在 Danbooru 上没有词条,点开必空
class CompletionPanel extends ConsumerStatefulWidget {
  const CompletionPanel({
    super.key,
    required this.result,
    required this.maxHeight,
    required this.onPick,
    required this.onInsert,
    required this.onCollapse,
  });

  final SuggestResult result;
  final double maxHeight;

  /// 行主体点按:替换光标处半词并收起(交给页面)
  final void Function(Suggestion) onPick;

  /// `+` 连续插入:追加为新标签,面板保持展开
  final void Function(Suggestion) onInsert;

  /// 下滑 / 抓手 / 底部提示:收起回形态 A 并唤起键盘
  final VoidCallback onCollapse;

  @override
  ConsumerState<CompletionPanel> createState() => _CompletionPanelState();
}

class _CompletionPanelState extends ConsumerState<CompletionPanel> {
  bool _byHeat = true; // 排序:true=热度 / false=字母
  final Set<SuggestionKind> _collapsed = {}; // 折叠的分节
  String? _wikiOpen; // 当前展开 Wiki 预览的行(按 text 记)
  final Map<String, WikiPreview?> _wiki = {}; // text → 预览(null=无/失败)
  final Set<String> _wikiLoading = {};

  Future<void> _loadWiki(String tag) async {
    if (_wiki.containsKey(tag) || _wikiLoading.contains(tag)) return;
    setState(() => _wikiLoading.add(tag));
    final w = await ref.read(tagCompletionProvider).fetchWiki(tag);
    if (!mounted) return;
    setState(() {
      _wikiLoading.remove(tag);
      _wiki[tag] = w;
    });
  }

  List<Suggestion> _sorted(List<Suggestion> xs) {
    final c = [...xs];
    if (_byHeat) {
      c.sort((a, b) => b.count.compareTo(a.count));
    } else {
      c.sort((a, b) => a.text.toLowerCase().compareTo(b.text.toLowerCase()));
    }
    return c;
  }

  String? _subtitle(Suggestion s) {
    switch (s.kind) {
      case SuggestionKind.character:
        return [
          s.trans,
          s.source,
        ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
      case SuggestionKind.work:
        return [
          s.trans,
          s.note,
        ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
      case SuggestionKind.oc:
        return s.note ?? s.trans;
      case SuggestionKind.tag:
        return s.trans;
      case SuggestionKind.artist:
        return s.trans;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    final sections = <(SuggestionKind, String, List<Suggestion>)>[
      (SuggestionKind.artist, '画师', widget.result.artists),
      (SuggestionKind.character, '角色', widget.result.characters),
      (SuggestionKind.oc, '我的 OC', widget.result.ocs),
      (SuggestionKind.work, '作品', widget.result.works),
      (SuggestionKind.tag, '标签', widget.result.tags),
    ].where((e) => e.$3.isNotEmpty).toList();

    final rows = <Widget>[];
    for (final (kind, label, raw) in sections) {
      final items = _sorted(raw);
      rows.add(_sectionHeader(kind, label, items.length));
      if (!_collapsed.contains(kind)) {
        for (final s in items) {
          rows.add(_row(s));
        }
      }
    }

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: widget.maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _handle(),
              _header(),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: rows,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 抓手 / 头部 / 底部 ----

  /// 与横向态那枚同款(同一个 [CompletionGrip]):一上一下是同一个交互的两头,
  /// 一边有底一边裸着会显得是两个东西。
  Widget _handle() => Center(
    child: CompletionGrip(
      icon: Icons.keyboard_arrow_down_rounded,
      onTap: widget.onCollapse,
      onDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 120) widget.onCollapse();
      },
    ),
  );

  Widget _header() {
    final scheme = context.scheme;
    return Padding(
      // 右边距 4:排序按钮自带 8 内衬,合起来正好与下方行尾圆钮的 12 对齐
      padding: const EdgeInsets.fromLTRB(16, 2, 4, 6),
      child: Row(
        children: [
          Text(
            '补全结果',
            style: context.texts.titleSmall!.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            '${widget.result.total} 项',
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() => _byHeat = !_byHeat),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.swap_vert, size: 16, color: scheme.primary),
                    const SizedBox(width: 3),
                    Text(
                      _byHeat ? '热度' : 'A–Z',
                      style: context.texts.labelLarge!.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 分节头 / 行 / 预览卡 ----

  Widget _sectionHeader(SuggestionKind kind, String label, int n) {
    final scheme = context.scheme;
    final (icon, color) = suggestionGlyph(context, kind);
    final collapsed = _collapsed.contains(kind);
    return InkWell(
      onTap: () => setState(() {
        if (collapsed) {
          _collapsed.remove(kind);
        } else {
          _collapsed.add(kind);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 7),
            Text(
              label,
              style: context.texts.labelLarge!.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$n',
              style: context.texts.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: .6),
              ),
            ),
            if (collapsed) ...[
              const SizedBox(width: 8),
              Icon(Icons.expand_more, size: 16, color: scheme.outline),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(Suggestion s) {
    final scheme = context.scheme;
    final isWork = s.kind == SuggestionKind.work;
    // 眼睛 = Danbooru Wiki 预览。画师串是自建条目、OC 是本地条目,
    // Danbooru 上没有对应词条,给了按钮点开也是空,所以这两类不出。
    final canWiki =
        s.kind == SuggestionKind.tag || s.kind == SuggestionKind.character;
    final subtitle = _subtitle(s);
    final count = isWork ? null : formatCount(s.count);
    final open = _wikiOpen == s.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => widget.onPick(s),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        s.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleSmall!.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.bodySmall!.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (count != null) ...[
                  Text(
                    count,
                    style: mono(context, size: 12, color: scheme.outline),
                  ),
                  const SizedBox(width: 6),
                ],
                if (isWork) ...[
                  _diceBtn(s),
                  const SizedBox(width: 4),
                ] else if (canWiki) ...[
                  _eyeBtn(s, open),
                  const SizedBox(width: 4),
                ],
                _plusBtn(s),
              ],
            ),
          ),
        ),
        if (open && canWiki) _previewCard(s),
      ],
    );
  }

  /// 👁 Wiki 预览开关(标签 / 角色 / OC 行)
  Widget _eyeBtn(Suggestion s, bool open) {
    final scheme = context.scheme;
    return _circleBtn(
      icon: open ? Icons.visibility : Icons.visibility_outlined,
      fg: open ? scheme.primary : scheme.onSurfaceVariant,
      onTap: () {
        setState(() => _wikiOpen = open ? null : s.text);
        if (!open) _loadWiki(s.text);
      },
    );
  }

  /// 作品行:随机抽一个角色插入。**只有这个按钮**做抽取——点行主体和 `+`
  /// 都是直接插作品 tag 本身。抽取靠把预抽的 [Suggestion.randomPick] 送进
  /// insertText,让下游按常规插入路径处理。
  Widget _diceBtn(Suggestion s) {
    final (icon, color) = suggestionGlyph(context, s.kind);
    final pick = s.randomPick;
    return _circleBtn(
      icon: icon,
      fg: color,
      onTap: () =>
          widget.onPick(pick == null ? s : s.copyWith(insertText: pick)),
    );
  }

  Widget _circleBtn({
    required IconData icon,
    required Color fg,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(icon, size: 18, color: fg),
        ),
      ),
    );
  }

  /// `+` 连续插入
  Widget _plusBtn(Suggestion s) {
    final scheme = context.scheme;
    return Material(
      color: scheme.primary,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.onInsert(s),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(Icons.add, size: 19, color: scheme.onPrimary),
        ),
      ),
    );
  }

  Widget _previewCard(Suggestion s) {
    final scheme = context.scheme;
    final isTag = s.kind == SuggestionKind.tag;
    final loading = _wikiLoading.contains(s.text);
    final wiki = _wiki[s.text];

    // tag 行走后端 wiki(中文摘要优先);其它实体行沿用本地副标题。
    String body;
    if (isTag) {
      if (wiki != null && wiki.hasText) {
        body = (wiki.summaryZh != null && wiki.summaryZh!.isNotEmpty)
            ? wiki.summaryZh!
            : (wiki.summary ?? '');
      } else {
        body = loading ? '' : '暂无 Wiki 摘要,可前往 Danbooru 查看。';
      }
    } else {
      body = _subtitle(s) ?? '';
    }
    final other = (isTag && wiki != null) ? wiki.otherNames : const <String>[];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '加载 Wiki…',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          else ...[
            if (body.isNotEmpty)
              Text(
                body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            if (other.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '别名: ${other.take(4).join(' / ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ],
          const SizedBox(height: 6),
          InkWell(
            onTap: () => _openWiki(s),
            borderRadius: BorderRadius.circular(6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Danbooru Wiki',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(Icons.arrow_forward, size: 13, color: scheme.primary),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openWiki(Suggestion s) {
    final url = danbooruWikiUrl(s.text);
    Clipboard.setData(ClipboardData(text: url));
    hintSnack(context, '已复制 Wiki 链接:$url', icon: Icons.check);
  }
}
