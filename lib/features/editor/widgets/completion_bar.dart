import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../data/suggestions.dart';

/// 类型 → 图标 + 颜色(横向态与竖向态共用)
(IconData, Color) suggestionGlyph(BuildContext context, SuggestionKind kind) {
  final pal = context.editor;
  switch (kind) {
    case SuggestionKind.character:
      return (Icons.person, pal.character);
    case SuggestionKind.oc:
      return (Icons.face, pal.oc);
    case SuggestionKind.work:
      return (Icons.casino, pal.work);
    case SuggestionKind.tag:
      return (Icons.label, context.scheme.onSurfaceVariant);
    case SuggestionKind.artist:
      return (Icons.brush, pal.artist);
  }
}

/// 形态 A · 默认横向态:吸在键盘正上方。
/// 自适应 1+1 —— 标签行常驻,实体行(角色/OC/作品)仅命中时滑入。
/// 上滑 / 点把手 → 展开为形态 B。
class CompletionBar extends StatelessWidget {
  const CompletionBar({
    super.key,
    required this.query,
    required this.result,
    this.loading = false,
    required this.onPick,
    required this.onAddRaw,
    required this.onExpand,
    required this.onClose,
  });

  final String query;
  final SuggestResult result;

  /// 查询进行中(结果尚未到)
  final bool loading;

  final void Function(Suggestion) onPick;

  /// 无匹配时把已输入文本直接加为新标签
  final VoidCallback onAddRaw;

  /// 上滑 / 点抓手 → 展开形态 B
  final VoidCallback onExpand;

  /// 下滑 → 关闭补全条
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    if (query.isEmpty) return const SizedBox.shrink();

    final entities = [
      ...result.artists,
      ...result.characters,
      ...result.ocs,
      ...result.works,
    ];

    return GestureDetector(
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -120) {
          onExpand();
        } else if (v > 120) {
          onClose();
        }
      },
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 把手:点一下或往上拉都展开
              InkWell(
                onTap: onExpand,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 22,
                    color: scheme.outline,
                  ),
                ),
              ),
              if (result.isEmpty)
                (loading ? _loadingHint(context) : _emptyHint(context))
              else ...[
                // 实体行(画师/角色/OC/作品)命中时才滑入,占上;标签行常驻在下。
                AnimatedSize(
                  duration: Motion.medium,
                  curve: Motion.emphasized,
                  alignment: Alignment.topCenter,
                  child: entities.isEmpty
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: _row(context, entities),
                        ),
                ),
                _row(context, result.tags),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyHint(BuildContext context) {
    final scheme = context.scheme;
    return InkWell(
      onTap: onAddRaw,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.add, size: 16, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '无匹配 · 点此把「$query」加为新标签',
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
    );
  }

  Widget _loadingHint(BuildContext context) {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
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
            '查询「$query」…',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, List<Suggestion> items) {
    if (items.isEmpty) return const SizedBox(width: double.infinity);
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) => _chip(context, items[i]),
      ),
    );
  }

  /// chip 副标题。横向态没有分节标题,光靠图标分不清 OC 与画师串,
  /// 所以这两类直接写类型名;角色带作品来源;其余用译文。
  String? _subtitle(Suggestion s) {
    switch (s.kind) {
      case SuggestionKind.oc:
        return '原创角色';
      case SuggestionKind.artist:
        return '画风';
      case SuggestionKind.character:
        final t = s.trans;
        if (t == null || t.isEmpty) return s.source;
        return s.source != null ? '$t · ${s.source}' : t;
      case SuggestionKind.work:
      case SuggestionKind.tag:
        return s.trans;
    }
  }

  Widget _chip(BuildContext context, Suggestion s) {
    final scheme = context.scheme;
    final (icon, iconColor) = suggestionGlyph(context, s.kind);
    final count = formatCount(s.count);
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onPick(s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 12, color: iconColor),
                  const SizedBox(width: 5),
                  Text(
                    s.text,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 5),
                    Text(
                      count,
                      style: mono(context, size: 9.5, color: scheme.outline),
                    ),
                  ],
                ],
              ),
              if (_subtitle(s) case final String sub when sub.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    sub,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
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
