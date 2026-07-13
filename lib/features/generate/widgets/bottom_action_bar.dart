import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/anlas_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../cost.dart';
import '../generate_state.dart';
import '../generation_controller.dart';
import '../loop_controller.dart';
import 'advanced_sheet.dart';
import 'img2img_card.dart';
import 'loop_sheet.dart';
import 'resolution_sheet.dart';

/// 吸底操作栏:参数读数 chips + 循环伴钮 + 生成主按钮
class BottomActionBar extends ConsumerWidget {
  const BottomActionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(generateProvider);
    final scheme = context.scheme;
    final p = state.params;
    final gen = ref.watch(generationProvider);
    final loop = ref.watch(loopStatusProvider);

    final isOpus = ref.watch(anlasProvider).asData?.value?.isOpus ?? false;
    final totalCost = estimateCost(state, isOpus: isOpus);

    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _ReadoutChip(
                  caption: '尺寸',
                  value: '${p.width}×${p.height}',
                  onTap: () => showResolutionSheet(context),
                ),
                const SizedBox(width: 8),
                _ReadoutChip(
                  caption: '步数',
                  value: '${p.steps}',
                  onTap: () => showAdvancedSheet(context),
                ),
                const Spacer(),
                _ReadoutChip(
                  icon: Icons.tune,
                  value: '高级',
                  valueMuted: true,
                  onTap: () => showAdvancedSheet(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                // 底图伴钮:选相册图设为图生图底图(已有底图时高亮,点击更换)
                Builder(
                  builder: (context) {
                    final hasI2i = state.img2img?.image != null;
                    return Tooltip(
                      message: hasI2i ? '更换图生图底图' : '导入图生图底图',
                      child: AnimatedContainer(
                        duration: Motion.fast,
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: hasI2i
                              ? scheme.primaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: hasI2i
                                ? scheme.primary
                                : scheme.outline.withValues(alpha: .7),
                            width: 1.5,
                          ),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(15),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => pickImg2ImgImage(context, ref),
                            child: Center(
                              child: Icon(
                                hasI2i ? Icons.image : Icons.input,
                                size: 22,
                                color: hasI2i
                                    ? scheme.onPrimaryContainer
                                    : scheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 9),
                // 循环伴钮:进循环面板(选张数并开始);运行中高亮,面板里可停
                Tooltip(
                  message: '循环生成',
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: loop.active
                          ? scheme.primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: loop.active
                            ? scheme.primary
                            : scheme.outline.withValues(alpha: .7),
                        width: 1.5,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(15),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => showLoopSheet(context),
                        child: Center(
                          child: Icon(
                            Icons.autorenew,
                            size: 22,
                            color: loop.active
                                ? scheme.onPrimaryContainer
                                : scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                // 生成主按钮:空闲=单张生成(循环从伴钮面板启动);
                // 生成中=进度条(重绘 CTA 同款),循环中叠「停止」可点。
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: gen.busy
                        ? _BusyBar(
                            gen: gen,
                            loop: loop,
                            onStop: loop.active && !loop.stopping
                                ? () => ref
                                      .read(loopStatusProvider.notifier)
                                      .stop()
                                : null,
                          )
                        : FilledButton(
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(26),
                              ),
                            ),
                            onPressed: () => ref
                                .read(generationProvider.notifier)
                                .generate(),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.auto_awesome,
                                  size: 20,
                                  color: scheme.onPrimary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '生成',
                                  style: context.texts.titleMedium!.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onPrimary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                AnimatedSwitcher(
                                  duration: Motion.fast,
                                  child: _PillChip(
                                    key: ValueKey(totalCost),
                                    text: totalCost == 0
                                        ? '免费'
                                        : '$totalCost Anlas',
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 生成中的主按钮区:化作进度条(重绘 CTA 同款视觉——浅底 + 半透明
/// primary 填充 + 居中读数)。循环中居中内容变「停止 · 第 n/N 张」且可点。
class _BusyBar extends StatelessWidget {
  const _BusyBar({required this.gen, required this.loop, this.onStop});

  final GenStatus gen;
  final LoopStatus loop;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final style = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w800,
      color: scheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final Widget center;
    if (loop.active) {
      final batch =
          '第 ${loop.batch}${loop.total > 0 ? '/${loop.total}' : ''} 张';
      center = loop.stopping
          ? Text('$batch · 本张后停止…', style: style)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.stop_rounded, size: 20, color: scheme.onSurface),
                const SizedBox(width: 5),
                Text('停止', style: style),
                const SizedBox(width: 8),
                Text(
                  batch,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            );
    } else {
      center = Text(
        gen.progress != null
            ? '${gen.step} / ${gen.total}'
            : (gen.note ?? '生成中…'),
        style: style,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: Stack(
        fit: StackFit.expand,
        children: [
          LinearProgressIndicator(
            value: gen.progress,
            backgroundColor: scheme.surfaceContainerHigh,
            color: scheme.primary.withValues(alpha: .38),
          ),
          if (onStop != null)
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onStop,
                child: Center(child: center),
              ),
            )
          else
            Center(child: center),
        ],
      ),
    );
  }
}

/// 主按钮内的信息胶囊(成本预估 / 循环第 n/N 张)。
class _PillChip extends StatelessWidget {
  const _PillChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.onPrimary.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimary,
        ),
      ),
    );
  }
}

class _ReadoutChip extends StatelessWidget {
  const _ReadoutChip({
    this.caption,
    this.icon,
    required this.value,
    this.valueMuted = false,
    required this.onTap,
  });

  final String? caption;
  final IconData? icon;
  final String value;
  final bool valueMuted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: SizedBox(
            height: 38,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 17, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 5),
                ],
                if (caption != null) ...[
                  Text(
                    caption!,
                    style: TextStyle(fontSize: 10, color: scheme.outline),
                  ),
                  const SizedBox(width: 5),
                ],
                AnimatedSwitcher(
                  duration: Motion.fast,
                  child: Text(
                    value,
                    key: ValueKey(value),
                    style: valueMuted
                        ? context.texts.bodyMedium!.copyWith(
                            color: scheme.onSurfaceVariant,
                          )
                        : mono(context, size: 13),
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
