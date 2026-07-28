import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/generation_controller.dart' show GenStatus;
import '../../generate/widgets/common.dart' show StripeThumb;
import '../models.dart';
import 'gallery_grid_sheet.dart';
import 'result_badge_chip.dart';
import 'result_thumb.dart';
import '../../../core/util/haptics.dart';

/// 底部历史胶片条:横向缩略图(选中环 + 角标)+ 尾部「›」展开全部网格。
/// 生成中头部插一张占位卡(逐帧预览 + 进度条),点它回到生成视角,
/// 点历史缩略图切走看历史 —— 对齐 web 桌面端的占位卡交互。
class FilmStrip extends StatelessWidget {
  const FilmStrip({
    super.key,
    required this.results,
    required this.selectedId,
    required this.onSelect,
    this.gen,
    this.genActive = false,
    this.onTapGen,
  });

  final List<ResultImage> results;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  /// 非空 = 生成中,头部显示占位卡。
  final GenStatus? gen;

  /// 占位卡是否为当前画布视角(选中环)。
  final bool genActive;
  final VoidCallback? onTapGen;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final gen = this.gen;
    final extra = gen != null ? 1 : 0;
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
                  itemCount: results.length + extra,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    if (gen != null && i == 0) {
                      return _GenThumb(
                        gen: gen,
                        active: genActive,
                        onTap: onTapGen,
                      );
                    }
                    final r = results[i - extra];
                    return _FilmThumb(
                      result: r,
                      selected:
                          r.id == selectedId && !(gen != null && genActive),
                      onTap: () => onSelect(r.id),
                      // 长按:直达网格多选并预选此张(快速删除/批量保存入口)
                      onLongPress: () {
                        Haptics.medium();
                        showGalleryGrid(context, selectId: r.id);
                      },
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
                      child: Icon(
                        Icons.chevron_right,
                        size: 24,
                        color: scheme.onSurfaceVariant,
                      ),
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

/// 生成中占位卡:逐帧预览(未到帧显斜纹)+ 底部细进度条。
/// 点击回到生成视角;active 时亮选中环。
class _GenThumb extends StatelessWidget {
  const _GenThumb({required this.gen, required this.active, this.onTap});

  final GenStatus gen;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    const h = 62.0;
    final aspect = (gen.width > 0 && gen.height > 0)
        ? gen.width / gen.height
        : 1.0;
    final w = (h * aspect).clamp(40.0, 116.0);
    final preview = gen.preview;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: active ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        padding: const EdgeInsets.all(2),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (preview != null)
                  Image.memory(
                    preview,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                else
                  StripeThumb(width: w, height: h, radius: 0),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SizedBox(
                    height: 3,
                    child: LinearProgressIndicator(
                      value: gen.progress, // null = 准备中,不确定动画
                      backgroundColor: Colors.black.withValues(alpha: .25),
                      valueColor: AlwaysStoppedAnimation(scheme.primary),
                    ),
                  ),
                ),
              ],
            ),
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
    this.onLongPress,
  });

  final ResultImage result;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    const h = 62.0;
    final w = (h * result.aspect).clamp(40.0, 116.0);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
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
