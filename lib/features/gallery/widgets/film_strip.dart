import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/generation_controller.dart' show GenStatus;
import '../../generate/widgets/common.dart' show StripeThumb;
import '../models.dart';
import 'gallery_grid_sheet.dart';
import 'result_badge_chip.dart';
import 'result_thumb.dart';
import '../../../core/util/haptics.dart';

// ---- 缩略图几何:**渲染与滚动定位共用这一组常数,谁都别再各写一份** ----
//
// 一枚条目的占位宽 = 图宽 + 内衬 2×2 + 边框 2×2。边框那 4px 极易漏算 ——
// 未选中时颜色是 transparent,肉眼看不见,但**照样占布局空间**。漏掉它
// 每张少算 4px,几十张累积上百像素,表现为自动滚动总差一截(实机反馈)。

const _thumbH = 62.0;
const _thumbPad = 2.0; // AnimatedContainer 内衬
const _thumbBorder = 2.0; // 选中环(透明时也占位)
const _thumbGap = 8.0; // ListView.separated 分隔
const _stripPadH = 12.0; // ListView 水平 padding

// 「›」是纯悬浮层:滚动区铺满全宽,缩略图从它底下直接穿过去,一寸不让。
const _moreSize = 44.0; // 圆钮直径
const _moreRight = 12.0; // 距右边缘

double _thumbImgW(double aspect) => (_thumbH * aspect).clamp(40.0, 116.0);

/// 条目在滚动轴上的完整占位宽(含内衬与边框)。
double _thumbSlotW(double aspect) =>
    _thumbImgW(aspect) + (_thumbPad + _thumbBorder) * 2;

/// 底部历史胶片条:横向缩略图(选中环 + 角标)+ 尾部「›」展开全部网格。
/// 生成中头部插一张占位卡(逐帧预览 + 进度条),点它回到生成视角,
/// 点历史缩略图切走看历史 —— 对齐 web 桌面端的占位卡交互。
/// 选中项变化(含画布横滑切图、从展开页跳选)时自动滚动,把选中项摆到视野中央。
class FilmStrip extends StatefulWidget {
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
  State<FilmStrip> createState() => _FilmStripState();
}

class _FilmStripState extends State<FilmStrip> {
  final _sc = ScrollController();

  @override
  void initState() {
    super.initState();
    // 冷启动的选中项可能在条中段,布局完成后滚到可见
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void didUpdateWidget(FilmStrip old) {
    super.didUpdateWidget(old);
    if (old.selectedId != widget.selectedId ||
        old.results.length != widget.results.length ||
        (old.gen != null) != (widget.gen != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  /// 把选中缩略图滚到**视野中央**。位置按渲染同款公式推算(缩略图宽 +
  /// 容器 padding 4 + 分隔 8),不去量已构建的布局 —— ListView 视野外的项
  /// 根本没建出来,量不着。
  ///
  /// 居中而非"最小滚动量刚好露出来":后者在横滑连切时会让选中项一直贴着
  /// 边缘走(看不出前后还有几张),从展开页跳选一张远处的图时也只是刚好
  /// 蹭进屏幕。首尾几张自然贴边(clamp 到滚动范围),那是应该的。
  void _reveal() {
    if (!mounted || !_sc.hasClients) return;
    final id = widget.selectedId;
    if (id == null) return;
    final i = widget.results.indexWhere((r) => r.id == id);
    if (i < 0) return;
    var x = _stripPadH;
    if (widget.gen case final g?) {
      final aspect = (g.width > 0 && g.height > 0) ? g.width / g.height : 1.0;
      x += _thumbSlotW(aspect) + _thumbGap; // 生成中占位卡排在头部
    }
    for (var k = 0; k < i; k++) {
      x += _thumbSlotW(widget.results[k].aspect) + _thumbGap;
    }
    final w = _thumbSlotW(widget.results[i].aspect);
    final vp = _sc.position.viewportDimension;
    final t = (x + w / 2 - vp / 2).clamp(0.0, _sc.position.maxScrollExtent);
    if ((t - _sc.offset).abs() < 1) return;
    _sc.animateTo(t, duration: Motion.medium, curve: Motion.emphasized);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final gen = widget.gen;
    final extra = gen != null ? 1 : 0;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: SizedBox(
          height: 68,
          child: Stack(
            children: [
              Positioned.fill(
                child: ListView.separated(
                  controller: _sc,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: _stripPadH),
                  itemCount: widget.results.length + extra,
                  separatorBuilder: (_, _) => const SizedBox(width: _thumbGap),
                  itemBuilder: (context, i) {
                    if (gen != null && i == 0) {
                      return _GenThumb(
                        gen: gen,
                        active: widget.genActive,
                        onTap: widget.onTapGen,
                      );
                    }
                    final r = widget.results[i - extra];
                    return _FilmThumb(
                      result: r,
                      selected:
                          r.id == widget.selectedId &&
                          !(gen != null && widget.genActive),
                      onTap: () => widget.onSelect(r.id),
                      // 长按:直达网格多选并预选此张(快速删除/批量保存入口)
                      onLongPress: () {
                        Haptics.medium();
                        showGalleryGrid(context, selectId: r.id);
                      },
                    );
                  },
                ),
              ),
              // 悬浮「›」展开全部:压在缩略图之上,靠投影拉开层次
              Positioned(
                top: 0,
                bottom: 0,
                right: _moreRight,
                child: Center(
                  child: Material(
                    color: scheme.surfaceContainerHighest,
                    elevation: 4,
                    shadowColor: Colors.black.withValues(alpha: .45),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => showGalleryGrid(context),
                      child: SizedBox(
                        width: _moreSize,
                        height: _moreSize,
                        child: Icon(
                          Icons.chevron_right,
                          size: 24,
                          color: scheme.onSurfaceVariant,
                        ),
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
    const h = _thumbH;
    final aspect = (gen.width > 0 && gen.height > 0)
        ? gen.width / gen.height
        : 1.0;
    final w = _thumbImgW(aspect);
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
            width: _thumbBorder,
          ),
        ),
        padding: const EdgeInsets.all(_thumbPad),
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
    const h = _thumbH;
    final w = _thumbImgW(result.aspect);
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
            width: _thumbBorder,
          ),
        ),
        padding: const EdgeInsets.all(_thumbPad),
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
