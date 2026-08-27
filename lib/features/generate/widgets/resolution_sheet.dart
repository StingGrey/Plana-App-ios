import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../generate_state.dart';
import '../models.dart';
import '../res_rules.dart';
import 'common.dart';

const _customTab = '自定义';

// 画布满格对应的真实像素(两轴一致);矩形左上角锚定,右下角拖拽定 W/H。
final double _axisMax = kMaxDim.toDouble();

// 可视化配色(在浅色画布上可读,语义同 web:绿=免费线,红=上限线)。
const _vizFree = FixedSemantic.ok;
const _vizOver = FixedSemantic.danger;

/// 分辨率 Sheet:预设三档(小图免费/大图/壁纸)+ 自定义档(拖拽画布)
/// + 统一档位状态条(MP·比例·免费/付费/超限)+ 确认生效。数值/交互对齐 web 桌面端。
Future<void> showResolutionSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => const _ResolutionSheet(),
  );
}

class _ResolutionSheet extends ConsumerStatefulWidget {
  const _ResolutionSheet();

  @override
  ConsumerState<_ResolutionSheet> createState() => _ResolutionSheetState();
}

class _ResolutionSheetState extends ConsumerState<_ResolutionSheet> {
  late String tab;

  /// 最后停留的预设页签:自定义档下预设行仍要渲染(CrossFade 常驻两子树)。
  late String lastPresetTab;
  late SizePreset selected;
  late int customW;
  late int customH;

  @override
  void initState() {
    super.initState();
    final p = ref.read(generateProvider).params;
    tab = sizeTabs.keys.first;
    selected = sizeTabs[tab]!.first;
    customW = snapDim(p.width);
    customH = snapDim(p.height);
    var matched = false;
    for (final entry in sizeTabs.entries) {
      for (final preset in entry.value) {
        if (preset.width == p.width && preset.height == p.height) {
          tab = entry.key;
          selected = preset;
          matched = true;
        }
      }
    }
    // 当前尺寸不是任何预设(如图生图按底图设的怪尺寸)→ 落在自定义档回显。
    if (!matched) tab = _customTab;
    lastPresetTab = _isCustom ? sizeTabs.keys.first : tab;
  }

  bool get _isCustom => tab == _customTab;
  int get _effW => _isCustom ? customW : selected.width;
  int get _effH => _isCustom ? customH : selected.height;

  void _setCustom(int w, int h) => setState(() {
    customW = w.clamp(kMinDim, kMaxDim);
    customH = h.clamp(kMinDim, kMaxDim);
  });

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final over = classifyPixels(_effW, _effH) == PixelTier.over;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '分辨率',
                  style: context.texts.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 20),
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: [
              for (final t in sizeTabs.keys)
                ButtonSegment(value: t, label: Text(t)),
              const ButtonSegment(value: _customTab, label: Text(_customTab)),
            ],
            selected: {tab},
            onSelectionChanged: (s) => setState(() {
              tab = s.first;
              if (!_isCustom) {
                lastPresetTab = tab;
                selected = sizeTabs[tab]!.first;
              }
            }),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 14),
          // CrossFade 同步动画高度与透明度:预设行(矮)↔ 画布(高)切换不跳变
          AnimatedCrossFade(
            duration: Motion.medium,
            sizeCurve: Motion.emphasized,
            crossFadeState: _isCustom
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: Row(
              children: [
                for (final p in sizeTabs[lastPresetTab]!) ...[
                  Expanded(
                    child: _PresetCard(
                      preset: p,
                      selected: selected == p,
                      onTap: () => setState(() => selected = p),
                    ),
                  ),
                  if (p != sizeTabs[lastPresetTab]!.last)
                    const SizedBox(width: 10),
                ],
              ],
            ),
            secondChild: _CanvasEditor(
              width: customW,
              height: customH,
              onChanged: _setCustom,
            ),
          ),
          const SizedBox(height: 12),
          _StatusStrip(width: _effW, height: _effH),
          const SizedBox(height: 10),
          const InfoNote(
            '免费档(≤1.05MP)· Opus ≤28 步单张免费;更大按张扣 Anlas',
            icon: Icons.info_outline,
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: over
                ? null
                : () {
                    ref.read(generateProvider.notifier).setSize(_effW, _effH);
                    Navigator.pop(context);
                  },
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: Text(
              over ? '超出像素上限' : '确认 · $_effW×$_effH',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// 档位状态条:MP · 比例 + 免费/付费/超限徽章(与 web classifyPixelStatus 同义)。
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.width, required this.height});

  final int width;
  final int height;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final tier = classifyPixels(width, height);
    final (label, color) = switch (tier) {
      PixelTier.free => ('免费', scheme.tertiary),
      PixelTier.paid => ('付费', scheme.primary),
      PixelTier.over => ('超限', scheme.error),
    };
    return Row(
      children: [
        Text(
          '${megapixels(width, height).toStringAsFixed(2)} MP',
          style: mono(
            context,
            size: 12.5,
          ).copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Text('·', style: TextStyle(color: scheme.outline)),
        const SizedBox(width: 8),
        Text(
          formatAspectRatio(width, height),
          style: mono(
            context,
            size: 12.5,
          ).copyWith(color: scheme.onSurfaceVariant),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// 自定义档:拖拽画布(左上锚定,右下角把手定 W/H)+ 读数/交换 + 缩到免费/上限。
/// 触屏在画布任意处按下/拖动即把右下角吸到手指,较桌面「抓把手」更顺。
class _CanvasEditor extends StatelessWidget {
  const _CanvasEditor({
    required this.width,
    required this.height,
    required this.onChanged,
  });

  final int width;
  final int height;
  final void Function(int w, int h) onChanged;

  void _fromLocal(Offset local, double side) {
    final fx = (local.dx / side).clamp(0.0, 1.0);
    final fy = (local.dy / side).clamp(0.0, 1.0);
    final w = snapDim((fx * _axisMax).round());
    final h = snapDim((fy * _axisMax).round());
    onChanged(w, h);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final tier = classifyPixels(width, height);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, cons) {
              final side = (cons.maxWidth.isFinite ? cons.maxWidth : 280.0)
                  .clamp(0.0, 300.0)
                  .toDouble();
              return SizedBox(
                width: side,
                height: side,
                child: GestureDetector(
                  // 用手势识别器抢占竞技场,避免竖向拖被底部浮层的「下拉关闭」偷走。
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (d) => _fromLocal(d.localPosition, side),
                  onPanUpdate: (d) => _fromLocal(d.localPosition, side),
                  child: CustomPaint(
                    painter: _ResCanvasPainter(
                      width: width,
                      height: height,
                      scheme: scheme,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        // 读数 + 动作:交换钮挪到长宽之间(替代 ×)省出横向空间;动作组用 Wrap,
        // 数值很大又同时出两个 chip 时整组自动换行,不再把「缩到免费」挤出界。
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$width',
                  style: mono(
                    context,
                    size: 16,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                _SwapBtn(onTap: () => onChanged(height, width)),
                const SizedBox(width: 6),
                Text(
                  '$height',
                  style: mono(
                    context,
                    size: 16,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tier == PixelTier.over) ...[
                  _QuickChip(
                    '缩到上限',
                    onTap: () {
                      final r = clampToMaxPixels(width, height);
                      onChanged(r.w, r.h);
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                if (tier != PixelTier.free)
                  _QuickChip(
                    '缩到免费',
                    onTap: () {
                      final r = scaleToFree(width, height);
                      onChanged(r.w, r.h);
                    },
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _ResCanvasPainter extends CustomPainter {
  _ResCanvasPainter({
    required this.width,
    required this.height,
    required this.scheme,
  });

  final int width;
  final int height;
  final ColorScheme scheme;

  Color _tierColor(PixelTier t) => switch (t) {
    PixelTier.free => _vizFree,
    PixelTier.paid => scheme.primary,
    PixelTier.over => _vizOver,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(10),
    );

    // 底 + 圆角裁剪
    canvas.drawRRect(rrect, Paint()..color = scheme.surfaceContainerHigh);
    canvas.save();
    canvas.clipRRect(rrect);

    // 网格(每 256 真实像素一线)
    final grid = Paint()
      ..color = scheme.onSurface.withValues(alpha: .06)
      ..strokeWidth = .5;
    for (double px = 256; px < _axisMax; px += 256) {
      final c = px / _axisMax * s;
      canvas.drawLine(Offset(c, 0), Offset(c, s), grid);
      canvas.drawLine(Offset(0, c), Offset(s, c), grid);
    }

    // 等像素双曲线:免费线(绿)/上限线(红)
    _hyperbola(canvas, s, kFreePixelThreshold, _vizFree, 3, 3);
    _hyperbola(canvas, s, kMaxTotalPixels, _vizOver, 4, 3);

    // 当前尺寸矩形(左上锚定)
    final rw = (width / _axisMax).clamp(0.0, 1.0) * s;
    final rh = (height / _axisMax).clamp(0.0, 1.0) * s;
    final tier = classifyPixels(width, height);
    final col = _tierColor(tier);
    final rect = Rect.fromLTWH(0, 0, rw, rh);
    canvas.drawRect(rect, Paint()..color = col.withValues(alpha: .18));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = col,
    );

    // 右下角把手 + 抓握斜线
    final hc = Offset(rw, rh);
    final handle = RRect.fromRectAndRadius(
      Rect.fromCenter(center: hc, width: 22, height: 22),
      const Radius.circular(5),
    );
    canvas.drawRRect(handle, Paint()..color = col);
    final grip = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    for (final d in const [-4.0, 0.0, 4.0]) {
      canvas.drawLine(
        Offset(hc.dx + d, hc.dy + 4),
        Offset(hc.dx + 4, hc.dy + d),
        grip,
      );
    }

    canvas.restore();
    // 外描边
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = scheme.outlineVariant,
    );
  }

  /// w×h=pixels 的等像素线,离散成虚线路径(与 web buildHyperbolaPath 同构)。
  void _hyperbola(
    Canvas canvas,
    double s,
    int pixels,
    Color color,
    double on,
    double off,
  ) {
    final path = Path();
    var started = false;
    for (
      double xpx = kResSnapStep.toDouble();
      xpx <= _axisMax;
      xpx += kResSnapStep
    ) {
      final ypx = pixels / xpx;
      if (ypx > _axisMax) continue;
      final cx = xpx / _axisMax * s;
      final cy = ypx / _axisMax * s;
      if (!started) {
        path.moveTo(cx, cy);
        started = true;
      } else {
        path.lineTo(cx, cy);
      }
    }
    if (!started) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: .5);
    canvas.drawPath(_dash(path, on, off), paint);
  }

  Path _dash(Path src, double on, double off) {
    final out = Path();
    for (final m in src.computeMetrics()) {
      var dist = 0.0;
      while (dist < m.length) {
        out.addPath(m.extractPath(dist, dist + on), Offset.zero);
        dist += on + off;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(_ResCanvasPainter old) =>
      old.width != width || old.height != height || old.scheme != scheme;
}

/// 长宽之间的交换钮:小巧圆钮,替代 ×,省出横向空间。
class _SwapBtn extends StatelessWidget {
  const _SwapBtn({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Tooltip(
      message: '交换宽高',
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(
              Icons.swap_horiz,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.compress,
                size: 15,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: context.texts.bodySmall!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final SizePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final ratio = preset.width / preset.height;
    const box = 44.0;
    final w = ratio >= 1 ? box : box * ratio;
    final h = ratio >= 1 ? box / ratio : box;
    return AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        color: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? scheme.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
            child: Column(
              children: [
                SizedBox(
                  width: box,
                  height: box,
                  child: Center(
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      width: w,
                      height: h,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: selected ? scheme.primary : scheme.outline,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  preset.name,
                  style: context.texts.bodySmall!.copyWith(
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                  ),
                ),
                Text(
                  preset.ratio,
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '${preset.width}×${preset.height}',
                  style: mono(
                    context,
                    size: 9.5,
                    weight: FontWeight.w500,
                  ).copyWith(color: scheme.outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
