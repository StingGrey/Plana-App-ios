import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 「我的」库的用户标签筛选行,灵感页与灵感库面板共用。
///
/// 轻量文字标签:没选中只有灰字,选中是浅主色底 + 主色字;不选 = 全部,
/// 再点选中的那个就取消。行末跟一个「管理」(标签池),随行一起滚,右缘渐隐。
/// 没有标签时整行不出。
class TagFilterChips extends StatelessWidget {
  const TagFilterChips({
    super.key,
    required this.tags,
    required this.filter,
    required this.onChanged,
    required this.onManageTags,
    this.edge = 14,
  });

  final List<String> tags;
  final String? filter;
  final ValueChanged<String?> onChanged;
  final VoidCallback onManageTags;
  final double edge;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final scheme = context.scheme;
    Widget chip({
      required String label,
      required bool selected,
      required VoidCallback onTap,
      IconData? icon,
    }) {
      final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Material(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: fg),
                    const SizedBox(width: 3),
                  ],
                  Text(
                    label,
                    style: context.texts.labelLarge!.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 40,
      // 右缘渐隐:标签多了被截在边上时不是一刀切
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          colors: const [Colors.black, Colors.black, Colors.transparent],
          stops: [0, 1 - 24 / rect.width.clamp(48, double.infinity), 1],
        ).createShader(rect),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(edge - 10, 4, edge + 12, 4),
          children: [
            for (final tag in tags)
              chip(
                label: '#$tag',
                selected: filter == tag,
                onTap: () => onChanged(filter == tag ? null : tag),
              ),
            chip(
              label: '管理',
              icon: Icons.tune,
              selected: false,
              onTap: onManageTags,
            ),
          ],
        ),
      ),
    );
  }
}
