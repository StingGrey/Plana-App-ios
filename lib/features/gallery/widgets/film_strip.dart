import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models.dart';
import 'gallery_grid_sheet.dart';
import 'result_badge_chip.dart';
import 'result_thumb.dart';

/// 底部历史胶片条:横向缩略图(选中环 + 角标)+ 尾部「›」展开全部网格。
class FilmStrip extends StatelessWidget {
  const FilmStrip({
    super.key,
    required this.results,
    required this.selectedId,
    required this.onSelect,
  });

  final List<ResultImage> results;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: SizedBox(
          height: 68,
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: results.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final r = results[i];
                    return _FilmThumb(
                      result: r,
                      selected: r.id == selectedId,
                      onTap: () => onSelect(r.id),
                    );
                  },
                ),
              ),
              // 尾部「›」展开全部
              Padding(
                padding: const EdgeInsets.only(right: 12, left: 4),
                child: Material(
                  color: scheme.surfaceContainerHighest,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => showGalleryGrid(context),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.chevron_right,
                          size: 24, color: scheme.onSurfaceVariant),
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

class _FilmThumb extends StatelessWidget {
  const _FilmThumb({
    required this.result,
    required this.selected,
    required this.onTap,
  });

  final ResultImage result;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    const h = 62.0;
    final w = (h * result.aspect).clamp(40.0, 116.0);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        padding: const EdgeInsets.all(2),
        child: Stack(
          children: [
            ResultThumb(result: result, width: w, height: h, radius: 9),
            if (result.badge != ResultBadge.none)
              Positioned(
                left: 4,
                top: 4,
                child: ResultBadgeChip(badge: result.badge),
              ),
          ],
        ),
      ),
    );
  }
}
