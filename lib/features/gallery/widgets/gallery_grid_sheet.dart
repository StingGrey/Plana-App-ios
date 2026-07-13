import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../gallery_state.dart';
import '../models.dart';
import 'result_badge_chip.dart';
import 'result_thumb.dart';

/// 「›」展开:全部作品网格弹层。点选一张即回填画布并关闭。
Future<void> showGalleryGrid(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _GalleryGridSheet(),
    );

class _GalleryGridSheet extends ConsumerWidget {
  const _GalleryGridSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(galleryProvider);
    final scheme = context.scheme;
    final h = MediaQuery.of(context).size.height * 0.82;

    return SizedBox(
      height: h,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Text('全部作品',
                    style: context.texts.titleMedium!
                        .copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('${state.results.length} 张',
                    style: context.texts.bodySmall!
                        .copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
              ),
              itemCount: state.results.length,
              itemBuilder: (_, i) {
                final r = state.results[i];
                return _GridThumb(
                  result: r,
                  selected: r.id == state.selectedId,
                  onTap: () {
                    ref.read(galleryProvider.notifier).select(r.id);
                    Navigator.of(context).pop();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GridThumb extends StatelessWidget {
  const _GridThumb({
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2.5),
          child: LayoutBuilder(
            builder: (_, c) => Stack(
              children: [
                ResultThumb(
                    result: result,
                    width: c.maxWidth,
                    height: c.maxWidth,
                    radius: 10),
                if (result.badge != ResultBadge.none)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: ResultBadgeChip(badge: result.badge),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
