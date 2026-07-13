import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/generate_state.dart';
import '../../generate/generation_controller.dart';
import '../../generate/models.dart';
import '../../generate/widgets/common.dart' show hintSnack, todoSnack;
import '../../inpaint/inpaint_overlay.dart';
import '../../../core/net/anlas_provider.dart';
import '../../../core/util/image_ops.dart';
import '../gallery_state.dart';
import '../models.dart';
import '../upscale_local.dart';
import '../upscale_model.dart';
import '../upscale_nai.dart';

/// 持久大图层:有字节 → `Image.memory`(gaplessPlayback);否则斜纹 + 尺寸占位。
/// 生成/查看全程复用同一个 Image widget,借 gaplessPlayback 桥接逐帧预览与终图,消除切换闪烁。
class GalleryImageLayer extends StatelessWidget {
  const GalleryImageLayer({
    super.key,
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List? bytes;
  final int width;
  final int height;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    if (bytes != null) {
      return ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: Center(
          child: Image.memory(
            bytes!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      );
    }
    return CustomPaint(
      painter: _HatchPainter(
        base: scheme.surfaceContainerHigh,
        stripe: scheme.surfaceContainerHighest,
      ),
      child: (width > 0 && height > 0)
          ? Center(
              child: Text(
                '$width × $height',
                style: mono(
                  context,
                  size: 20,
                  weight: FontWeight.w600,
                  color: scheme.onSurfaceVariant.withValues(alpha: .55),
                ),
              ),
            )
          : null,
    );
  }
}

/// 结果操作层:右侧竖排操作轨 + 左下 seed 芯片(叠在大图上)。
class ResultChrome extends StatelessWidget {
  const ResultChrome({super.key, required this.result});

  final ResultImage result;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(right: 12, bottom: 16, child: _ActionRail(result: result)),
        Positioned(left: 12, bottom: 16, child: _SeedChip(seed: result.seed)),
      ],
    );
  }
}

/// 浮动进度胶囊(浅色)。入场/离场的渐显渐隐由外层 AnimatedSwitcher 负责,这里只画静态样子。
class ProgressPill extends StatelessWidget {
  const ProgressPill({super.key, required this.status});

  final GenStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final p = status.progress;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .95),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .16),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 112,
            height: 6,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: p, // null = 准备中,走不确定动画
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(scheme.primary),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            p != null
                ? '${status.step}/${status.total}'
                : (status.note ?? '准备中'),
            style: mono(context, size: 13, color: scheme.onSurface),
          ),
        ],
      ),
    );
  }
}

class _ActionRail extends ConsumerWidget {
  const _ActionRail({required this.result});

  final ResultImage result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _RailButton(
          label: '重绘',
          icon: Icons.brush,
          onTap: () => _inpaint(context, ref),
        ),
        const SizedBox(height: 10),
        _RailButton(
          label: '放大',
          icon: Icons.open_in_full,
          onTap: () => _upscale(context, ref),
        ),
        const SizedBox(height: 10),
        _RailButton(
          label: '下载',
          icon: Icons.download,
          onTap: () => _download(context),
        ),
        const SizedBox(height: 10),
        _RailButton(
          label: '导入',
          icon: Icons.input,
          accent: true,
          onTap: () => todoSnack(context, '导入到创作'),
        ),
        const SizedBox(height: 10),
        _RailButton(
          label: '重新生成',
          icon: Icons.refresh,
          primary: true,
          onTap: () => _regenerate(context, ref),
        ),
      ],
    );
  }

  /// 重绘:图库画布原地切入涂抹编辑面板(非路由页)。参数快照缺失时
  /// 退回当前创作页状态,保证任何有像素的图都能重绘。
  void _inpaint(BuildContext context, WidgetRef ref) {
    final bytes = result.bytes;
    if (bytes == null) {
      hintSnack(context, '此图无像素数据', icon: Icons.error_outline);
      return;
    }
    final snap = result.input;
    final GenerateState input = snap ?? ref.read(generateProvider);
    ref
        .read(inpaintSessionProvider.notifier)
        .open(imageBytes: bytes, input: input);
  }

  /// 放大:弹方式面板(本地快/质 · NAI)→ 分发本地 ncnn / NAI 远程 → 进度 → 入库。
  Future<void> _upscale(BuildContext context, WidgetRef ref) async {
    final bytes = result.bytes;
    if (bytes == null) {
      hintSnack(context, '此图无像素数据', icon: Icons.error_outline);
      return;
    }
    final w = result.width, h = result.height;
    final naiOk = naiUpscaleSupportsSize(w, h);
    final redrawOk = result.input != null && redraw15xSupportsSize(w, h);

    // 1. 选方式(默认上次;不可用的方式回退本地快速)
    var current =
        ref.read(upscaleMethodProvider).value ?? UpscaleMethod.localFast;
    if ((current == UpscaleMethod.nai && !naiOk) ||
        (current == UpscaleMethod.redraw15x && !redrawOk)) {
      current = UpscaleMethod.localFast;
    }
    final method = await showModalBottomSheet<UpscaleMethod>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _UpscaleMethodSheet(
        current: current,
        naiEnabled: naiOk,
        redrawEnabled: redrawOk,
        hasInput: result.input != null,
        width: w,
        height: h,
      ),
    );
    if (method == null || !context.mounted) return;
    await ref.read(upscaleMethodProvider.notifier).set(method);
    if (!context.mounted) return;

    // 1.5× 重绘:走生成管线(画布流式预览),不弹放大对话框
    if (method == UpscaleMethod.redraw15x) {
      _redraw15x(context, ref);
      return;
    }

    // 2. 进度对话框(本地=tile 真进度条;NAI=不确定动画 + 阶段文案)
    final stage = ValueNotifier<String>('准备…');
    final frac = ValueNotifier<double?>(null);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _UpscaleProgressDialog(method: method, stage: stage, frac: frac),
    );

    // 3. 执行:按方式分发
    try {
      late final Uint8List png;
      late final int outW;
      late final int outH;
      if (method.local) {
        final r = await upscaleLocal(
          bytes,
          model: method.asset!,
          onStage: (s) => stage.value = s,
          onProgress: (f) => frac.value = f,
        );
        png = r.png;
        outW = r.width;
        outH = r.height;
      } else {
        final r = await upscaleNai(
          ref,
          bytes,
          width: w,
          height: h,
          onStage: (s) => stage.value = s,
        );
        png = r.png;
        outW = r.width;
        outH = r.height;
      }
      // 入库:新条目 + 4x 角标,沿用原图 seed/输入参数
      ref
          .read(galleryProvider.notifier)
          .addResult(
            bytes: png,
            width: outW,
            height: outH,
            seed: result.seed,
            badge: ResultBadge.upscaled,
            input: result.input,
          );
      if (!method.local) ref.read(anlasProvider.notifier).refresh();
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) {
        hintSnack(
          context,
          '${method.label}完成 $outW×$outH,已存入图库',
          icon: Icons.check_circle_outline,
        );
      }
    } catch (e) {
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) {
        hintSnack(context, '超分失败: $e', icon: Icons.error_outline);
      }
    } finally {
      stage.dispose();
      frac.dispose();
    }
  }

  /// 1.5× 重绘放大:以 1.5 倍尺寸 img2img 重新生成(走生成管线,结果画布流式 + 自动入库)。
  void _redraw15x(BuildContext context, WidgetRef ref) {
    final input = result.input;
    final bytes = result.bytes;
    if (input == null || bytes == null) {
      hintSnack(context, '缺少参数快照,无法重绘放大', icon: Icons.error_outline);
      return;
    }
    final t = img2imgResolution(
      (result.width * 1.5).round(),
      (result.height * 1.5).round(),
    );
    ref
        .read(generationProvider.notifier)
        .generate(
          using: input.copyWith(
            img2img: Img2ImgConfig(
              image: bytes,
              strength: kRedraw15xStrength,
              noise: kRedraw15xNoise,
            ),
            params: input.params.copyWith(width: t.w, height: t.h, seed: ''),
          ),
        );
    hintSnack(
      context,
      '开始 1.5× 重绘 ${t.w}×${t.h}(生成中)',
      icon: Icons.auto_fix_high,
    );
  }

  /// 存当前图 PNG 到系统相册(gal;Android 10+ 免权限走 MediaStore)。
  Future<void> _download(BuildContext context) async {
    final bytes = result.bytes;
    if (bytes == null) return;
    try {
      final ok = await Gal.hasAccess() || await Gal.requestAccess();
      if (!ok) {
        if (context.mounted) {
          hintSnack(context, '未获相册权限', icon: Icons.error_outline);
        }
        return;
      }
      await Gal.putImageBytes(bytes, name: 'plana_${result.seed}');
      if (context.mounted) {
        hintSnack(context, '已保存到相册', icon: Icons.check_circle_outline);
      }
    } on GalException catch (_) {
      if (context.mounted) {
        hintSnack(context, '保存失败', icon: Icons.error_outline);
      }
    }
  }

  /// 按本图参数、换随机种子出一张新图(不改用户当前编辑器状态)。
  void _regenerate(BuildContext context, WidgetRef ref) {
    final input = result.input;
    if (input == null) {
      hintSnack(context, '缺少参数快照,无法重新生成', icon: Icons.error_outline);
      return;
    }
    ref
        .read(generationProvider.notifier)
        .generate(
          using: input.copyWith(params: input.params.copyWith(seed: '')),
        );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.accent = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final double d = primary ? 58 : 48;
    final Color circleColor = primary
        ? scheme.primary
        : accent
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest;
    final Color iconColor = primary
        ? scheme.onPrimary
        : accent
        ? scheme.onSecondaryContainer
        : scheme.onSurface;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: circleColor,
          shape: const CircleBorder(),
          elevation: primary ? 3 : 1.5,
          shadowColor: scheme.shadow,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: d,
              height: d,
              child: Icon(icon, size: primary ? 27 : 22, color: iconColor),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: .82),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _SeedChip extends StatelessWidget {
  const _SeedChip({required this.seed});

  final int seed;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      elevation: 1.5,
      shadowColor: scheme.shadow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: '$seed'));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text('已复制种子 $seed')));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grain, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 7),
              Text('$seed', style: mono(context, size: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 斜纹占位(比缩略图更宽的条纹,大尺寸更耐看)。
class _HatchPainter extends CustomPainter {
  const _HatchPainter({required this.base, required this.stripe});

  final Color base;
  final Color stripe;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final sp = Paint()..color = stripe;
    const w = 14.0;
    for (double x = -size.height; x < size.width; x += w * 2) {
      final path = Path()
        ..moveTo(x, size.height)
        ..lineTo(x + size.height, 0)
        ..lineTo(x + size.height + w, 0)
        ..lineTo(x + w, size.height)
        ..close();
      canvas.drawPath(path, sp);
    }
  }

  @override
  bool shouldRepaint(covariant _HatchPainter old) =>
      old.base != base || old.stripe != stripe;
}

/// 放大档位选择面板:快速(lite)/ 质量(digital-art),点卡片即选中并开始。
/// 放大方式面板:本地(快/质,免费不限尺寸)+ NAI 官方(远程,限尺寸/扣点)。点即选并开始。
class _UpscaleMethodSheet extends StatelessWidget {
  const _UpscaleMethodSheet({
    required this.current,
    required this.naiEnabled,
    required this.redrawEnabled,
    required this.hasInput,
    required this.width,
    required this.height,
  });

  final UpscaleMethod current;
  final bool naiEnabled;
  final bool redrawEnabled;
  final bool hasInput;
  final int width;
  final int height;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SafeArea(
      // 抓手由 BottomSheetTheme(showDragHandle: true)统一提供,这里不再自画。
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                '放大方式',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ),
            _groupLabel(context, '本地 · 免费 · 不限尺寸'),
            _MethodTile(
              method: UpscaleMethod.localFast,
              selected: current == UpscaleMethod.localFast,
              enabled: true,
            ),
            const SizedBox(height: 8),
            _MethodTile(
              method: UpscaleMethod.localQuality,
              selected: current == UpscaleMethod.localQuality,
              enabled: true,
            ),
            const SizedBox(height: 16),
            _groupLabel(
              context,
              naiEnabled ? 'NAI 官方 · 联网 · 扣点' : 'NAI 官方 · 当前尺寸不支持',
            ),
            _MethodTile(
              method: UpscaleMethod.nai,
              selected: current == UpscaleMethod.nai,
              enabled: naiEnabled,
              disabledHint: naiEnabled
                  ? null
                  : '仅 832×1216 / 1216×832 / 1024²(当前 $width×$height)',
            ),
            const SizedBox(height: 16),
            _groupLabel(
              context,
              redrawEnabled ? 'NAI 重绘 · 图生图 · 扣点' : 'NAI 重绘 · 不可用',
            ),
            _MethodTile(
              method: UpscaleMethod.redraw15x,
              selected: current == UpscaleMethod.redraw15x,
              enabled: redrawEnabled,
              disabledHint: redrawEnabled
                  ? null
                  : (!hasInput ? '仅生成图可重绘(缺少参数快照)' : '目标尺寸超上限,请用更小的原图'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupLabel(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(left: 4, top: 2, bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: context.scheme.onSurfaceVariant,
      ),
    ),
  );
}

/// 单个方式卡片。禁用时(NAI 尺寸不符)置灰 + 不可点 + 显示原因。
class _MethodTile extends StatelessWidget {
  const _MethodTile({
    required this.method,
    required this.selected,
    required this.enabled,
    this.disabledHint,
  });

  final UpscaleMethod method;
  final bool selected;
  final bool enabled;
  final String? disabledHint;

  IconData get _icon => switch (method) {
    UpscaleMethod.localFast => Icons.bolt,
    UpscaleMethod.localQuality => Icons.auto_awesome,
    UpscaleMethod.nai => Icons.cloud_outlined,
    UpscaleMethod.redraw15x => Icons.auto_fix_high,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final titleColor = enabled
        ? scheme.onSurface
        : scheme.onSurfaceVariant.withValues(alpha: .5);
    final subColor = enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: .5);
    final iconColor = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: .5)
        : selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Material(
      color: !enabled
          ? scheme.surfaceContainerHighest.withValues(alpha: .45)
          : selected
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? () => Navigator.of(context).pop(method) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(_icon, color: iconColor),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          method.label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            method.badge,
                            style: TextStyle(fontSize: 10, color: subColor),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      disabledHint ?? method.desc,
                      style: TextStyle(fontSize: 12, color: subColor),
                    ),
                  ],
                ),
              ),
              if (selected && enabled)
                Icon(Icons.check_circle, color: scheme.primary, size: 20)
              else if (!enabled)
                Icon(
                  Icons.block,
                  color: scheme.onSurfaceVariant.withValues(alpha: .5),
                  size: 18,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 超分进度对话框:本地=tile 真进度条 + 百分比;NAI=不确定动画 + 阶段文案。
class _UpscaleProgressDialog extends StatelessWidget {
  const _UpscaleProgressDialog({
    required this.method,
    required this.stage,
    required this.frac,
  });

  final UpscaleMethod method;
  final ValueNotifier<String> stage;
  final ValueNotifier<double?> frac;

  IconData get _icon => switch (method) {
    UpscaleMethod.localFast => Icons.bolt,
    UpscaleMethod.localQuality => Icons.auto_awesome,
    UpscaleMethod.nai => Icons.cloud_outlined,
    UpscaleMethod.redraw15x => Icons.auto_fix_high,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return AlertDialog(
      title: Row(
        children: [
          Icon(_icon, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Text('${method.label} · 4×', style: const TextStyle(fontSize: 16)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: stage,
            builder: (_, s, _) => Text(
              s,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<double?>(
            valueListenable: frac,
            builder: (_, f, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: f,
                    minHeight: 8,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    f == null
                        ? (method.local ? '准备中…' : '处理中…')
                        : '${(f * 100).round()}%',
                    style: mono(context, size: 13, color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
