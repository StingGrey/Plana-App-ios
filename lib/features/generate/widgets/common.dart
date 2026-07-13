import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';

/// 拖动排序的浮起样式:替换 ReorderableListView 默认代理
/// (Material 白底 + 阴影),改为微放大、无底色 —— 圆角卡片/缩略图不穿帮。
Widget dragProxy(Widget child, int index, Animation<double> animation) =>
    AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeOut.transform(animation.value);
        return Transform.scale(scale: 1 + .06 * t, child: child);
      },
    );

/// 拖动排序开始的触感反馈(长按拾起)。
void dragStartHaptic(int _) => HapticFeedback.mediumImpact();

/// 拖动排序落定的触感反馈。
void dragEndHaptic(int _) => HapticFeedback.selectionClick();

/// 平滑展开/收起容器:高度用 SizeTransition,内容用 FadeTransition,
/// 展开时先长高再淡入、收起时先淡出再收拢 —— 避免内容"瞬间弹出"。
class ExpandBody extends StatefulWidget {
  const ExpandBody({super.key, required this.expanded, required this.child});

  final bool expanded;
  final Widget child;

  @override
  State<ExpandBody> createState() => _ExpandBodyState();
}

class _ExpandBodyState extends State<ExpandBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: widget.expanded ? 1 : 0,
  );

  late final Animation<double> _size = CurvedAnimation(
    parent: _c,
    curve: Motion.emphasized,
    reverseCurve: Easing.emphasizedAccelerate,
  );

  // 展开:内容在 30%~100% 淡入;收起:0%~55% 先淡出
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: const Interval(.3, 1, curve: Curves.easeOut),
    reverseCurve: const Interval(.45, 1, curve: Curves.easeIn),
  );

  @override
  void didUpdateWidget(covariant ExpandBody old) {
    super.didUpdateWidget(old);
    if (widget.expanded != old.expanded) {
      widget.expanded ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _size,
        alignment: Alignment.topCenter,
        // RepaintBoundary:动画期间内容不重绘,缓存为纹理,只做裁剪+透明合成
        child: FadeTransition(
          opacity: _fade,
          child: RepaintBoundary(child: widget.child),
        ),
      ),
    );
  }
}

/// 圆形图标按钮(卡片头部的 + / 管理器等)
class RoundIconBtn extends StatelessWidget {
  const RoundIconBtn(
    this.icon, {
    super.key,
    this.onTap,
    this.color,
    this.size = 36,
    this.iconSize = 20,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;
  final double size;
  final double iconSize;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: context.scheme.surfaceContainerHigh,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: iconSize, color: color ?? context.scheme.primary),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// 计数徽章(角色 2/6、Vibe 2 等)
class CountBadge extends StatelessWidget {
  const CountBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Motion.fast,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
      decoration: BoxDecoration(
        color: context.scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        text,
        style: context.texts.labelSmall!.copyWith(
          color: context.scheme.onTertiaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 参数滑杆:标签 + 数值读数 + Slider,展开卡与 Sheet 通用
class ParamSlider extends StatelessWidget {
  const ParamSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.valueText,
    this.caption,
    this.trailing,
    this.dense = false,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? valueText;
  final String? caption;
  final Widget? trailing;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final labelStyle = dense
        ? context.texts.labelSmall!.copyWith(color: context.scheme.onSurfaceVariant)
        : context.texts.bodySmall!.copyWith(color: context.scheme.onSurface);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: labelStyle)),
            if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
            Text(
              valueText ?? value.toStringAsFixed(2),
              style: mono(context, size: dense ? 11 : 13, color: context.scheme.primary),
            ),
          ],
        ),
        SizedBox(
          height: dense ? 26 : 32,
          child: SliderTheme(
            data: SliderThemeData(
              padding: EdgeInsets.zero,
              trackHeight: dense ? 3 : 4,
              thumbSize: WidgetStatePropertyAll(Size.fromRadius(dense ? 7 : 9)),
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        if (caption != null)
          Text(caption!,
              style: context.texts.labelSmall!.copyWith(color: context.scheme.outline)),
      ],
    );
  }
}

/// 斜纹占位缩略图(设计稿中的图片占位)
class StripeThumb extends StatelessWidget {
  const StripeThumb({
    super.key,
    required this.width,
    required this.height,
    this.radius = 11,
    this.onClose,
    this.label,
    this.image,
  });

  final double width;
  final double height;
  final double radius;
  final VoidCallback? onClose;
  final String? label;

  /// 有真实图则显示它(cover),否则斜纹占位。
  final Uint8List? image;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: image != null
                ? Image.memory(
                    image!,
                    width: width,
                    height: height,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                : CustomPaint(
                    size: Size(width, height),
                    painter: _StripePainter(
                      context.scheme.surfaceContainerHighest,
                      context.scheme.surfaceContainerHigh,
                    ),
                  ),
          ),
          if (onClose != null)
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: context.scheme.scrim.withValues(alpha: .6),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onClose,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: Icon(Icons.close, size: 12, color: context.scheme.onSurface),
                  ),
                ),
              ),
            ),
          if (label != null)
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: context.scheme.scrim.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  label!,
                  textAlign: TextAlign.center,
                  style: mono(context, size: 9, color: context.scheme.onSurface),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  const _StripePainter(this.a, this.b);

  final Color a;
  final Color b;

  @override
  void paint(Canvas canvas, Size size) {
    final paintA = Paint()..color = a;
    final paintB = Paint()..color = b;
    canvas.drawRect(Offset.zero & size, paintB);
    const w = 8.0;
    for (double x = -size.height; x < size.width; x += w * 2) {
      final path = Path()
        ..moveTo(x, size.height)
        ..lineTo(x + size.height, 0)
        ..lineTo(x + size.height + w, 0)
        ..lineTo(x + w, size.height)
        ..close();
      canvas.drawPath(path, paintA);
    }
  }

  @override
  bool shouldRepaint(covariant _StripePainter old) => old.a != a || old.b != b;
}

/// 卡片底部的说明行
class InfoNote extends StatelessWidget {
  const InfoNote(this.text, {super.key, this.icon = Icons.info_outline, this.color});

  final String text;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.scheme.outline;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: context.texts.labelSmall!
                  .copyWith(color: context.scheme.outline, height: 1.4)),
        ),
      ],
    );
  }
}

/// M3 shared-axis 全屏路由(编辑器等二级全屏页)
Route<T> sharedAxisRoute<T>(
  Widget page, {
  SharedAxisTransitionType type = SharedAxisTransitionType.vertical,
}) {
  return PageRouteBuilder<T>(
    transitionDuration: Motion.slow,
    reverseTransitionDuration: Motion.medium,
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, animation, secondary, child) => SharedAxisTransition(
      animation: animation,
      secondaryAnimation: secondary,
      transitionType: type,
      child: child,
    ),
  );
}

/// 参考图横条里的可选缩略图 —— Vibe / 角色参考 共用。
/// 不带删除角标(移除统一走详情区按钮),长按由外层拖动排序接管。
class RefThumb extends StatelessWidget {
  const RefThumb({
    super.key,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.width = 60,
    this.height = 60,
    this.image,
  });

  final bool selected;
  final VoidCallback onTap;
  final bool enabled;
  final double width;
  final double height;
  final Uint8List? image;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Stack(
          children: [
            AnimatedOpacity(
              duration: Motion.fast,
              opacity: enabled ? 1 : .35,
              child: StripeThumb(
                  width: width, height: height, radius: 11, image: image),
            ),
            if (!enabled)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Icon(Icons.visibility_off,
                        size: 22,
                        color: scheme.onSurface.withValues(alpha: .8)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 参考图启用/停用开关(裸电源图标)—— Vibe / 角色参考 共用
class RefEnableToggle extends StatelessWidget {
  const RefEnableToggle({super.key, required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(Icons.power_settings_new,
            size: 20, color: enabled ? scheme.tertiary : scheme.outline),
        tooltip: enabled ? '停用此参考图' : '启用',
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// 虚线「添加」格 —— Vibe / 角色参考 共用
class AddTile extends StatelessWidget {
  const AddTile({super.key, required this.onTap, this.width = 60, this.height = 60});

  final VoidCallback onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: CustomPaint(
          painter: DashedBorderPainter(scheme.outline),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 22, color: scheme.primary),
                const SizedBox(height: 2),
                Text('添加',
                    style: context.texts.labelSmall!
                        .copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 参考图详情头:「参考图 N」+ 文件名 + 移除药丸 —— Vibe / 角色参考 共用
class RefDetailHeader extends StatelessWidget {
  const RefDetailHeader({
    super.key,
    required this.index,
    required this.name,
    required this.onRemove,
    this.enableToggle,
    this.leadingAction,
  });

  final int index;
  final String name;
  final VoidCallback onRemove;

  /// 行首的启用/停用开关
  final Widget? enableToggle;

  /// 放在「移除」按钮左侧的额外控件(如角色参考的迁移模式切换)
  final Widget? leadingAction;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      children: [
        if (enableToggle != null) ...[enableToggle!, const SizedBox(width: 4)],
        Text('参考图 $index',
            style:
                context.texts.bodyLarge!.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        // Expanded 占满中段,把尾部(切换 + 移除)顶到最右
        Expanded(
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!
                  .copyWith(color: scheme.onSurfaceVariant)),
        ),
        if (leadingAction != null) ...[leadingAction!, const SizedBox(width: 8)],
        Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 6),
                  Text('移除',
                      style: context.texts.bodyMedium!
                          .copyWith(color: scheme.onSurface)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 虚线圆角边框
class DashedBorderPainter extends CustomPainter {
  const DashedBorderPainter(this.color);

  final Color color;
  static const double radius = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(radius)));
    const dash = 5.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, (d + dash).clamp(0, metric.length)),
          paint,
        );
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedBorderPainter old) => old.color != color;
}

/// 左划删除包装:endToStart 方向露出红色删除背景,松手触发删除 + 触感。
/// 原有的删除按钮保留作为可见替代入口。
class SwipeToDelete extends StatelessWidget {
  const SwipeToDelete({
    super.key,
    required this.itemKey,
    required this.onDelete,
    required this.child,
    this.borderRadius = 12,
  });

  final Key itemKey;
  final VoidCallback onDelete;
  final Widget child;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Dismissible(
      key: itemKey,
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: .45},
      onUpdate: (details) {
        // 越过阈值瞬间给一次轻触感,预告"松手即删"
        if (details.reached && !details.previousReached) {
          HapticFeedback.selectionClick();
        }
      },
      onDismissed: (_) {
        HapticFeedback.mediumImpact();
        onDelete();
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Icon(Icons.delete_outline, size: 22, color: scheme.onErrorContainer),
      ),
      child: child,
    );
  }
}

/// 通用确认弹窗(破坏性操作用红色确认键)。返回 true = 确认。
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(
            backgroundColor: context.scheme.error,
            foregroundColor: context.scheme.onError,
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

void todoSnack(BuildContext context, String what) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text('$what · 下一里程碑接入')));
}

/// 轻提示:带图标的浮层 snack,用于「分辨率已自动调整」这类被动变更告知。
void hintSnack(BuildContext context, String text,
    {IconData icon = Icons.info_outline}) {
  final scheme = context.scheme;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      duration: const Duration(seconds: 3),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: scheme.onInverseSurface),
          const SizedBox(width: 10),
          Flexible(child: Text(text)),
        ],
      ),
    ));
}
