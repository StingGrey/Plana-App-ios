import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'common.dart';

/// 创作页折叠卡的统一骨架:
/// 头部一行(图标·标题·徽章·内联元素·动作按钮·chevron),
/// 展开体用 AnimatedSize + FadeTransition 过渡。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    this.badge,
    this.inline = const [],
    this.actions = const [],
    this.expanded = false,
    this.onHeaderTap,
    this.body,
    this.muted = false,
  });

  final IconData icon;
  final String title;
  final Widget? badge;

  /// 头部标题与动作之间的内联元素(mini 缩略图、"未启用"等)
  final List<Widget> inline;
  final List<Widget> actions;
  final bool expanded;
  final VoidCallback? onHeaderTap;
  final Widget? body;

  /// 禁用观感(如图生图启用时的 Vibe 卡)
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final titleColor = muted ? scheme.onSurfaceVariant : scheme.onSurface;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onHeaderTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(15, 13, 13, 13),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 9),
                  Text(
                    title,
                    style: context.texts.bodyLarge!
                        .copyWith(fontWeight: FontWeight.w600, color: titleColor),
                  ),
                  if (badge != null) ...[const SizedBox(width: 8), badge!],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (final w in inline) ...[w, const SizedBox(width: 6)],
                      ],
                    ),
                  ),
                  for (final a in actions) ...[a, const SizedBox(width: 6)],
                  if (onHeaderTap != null)
                    AnimatedRotation(
                      turns: expanded ? .5 : 0,
                      duration: Motion.medium,
                      curve: Motion.emphasized,
                      child: Icon(Icons.expand_more, size: 22, color: scheme.outline),
                    ),
                ],
              ),
            ),
          ),
          ExpandBody(
            expanded: expanded && body != null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: body ?? const SizedBox(width: double.infinity),
            ),
          ),
        ],
      ),
    );
  }
}
