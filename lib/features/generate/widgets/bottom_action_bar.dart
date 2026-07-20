import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/anlas_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../cost.dart';
import '../gen_modules.dart';
import '../generate_state.dart';
import '../generation_controller.dart';
import '../loop_controller.dart';
import '../../import/import_panel.dart';
import 'advanced_sheet.dart';
import 'common.dart' show hintSnack;
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
    // 成本按实际会发送的内容估:隐藏模块的数据不发也不计
    final mods =
        ref.watch(genModulesProvider).value ?? const GenModuleSettings();
    final totalCost = estimateCost(
      stripHiddenModules(state, mods),
      isOpus: isOpus,
    );

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
                  value: isAnimaModel(p.model)
                      ? '${p.animaSteps}'
                      : '${p.steps}',
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
                // 导入图片:选相册图 → 解析元数据/用作参考的全屏导入面板
                Tooltip(
                  message: '导入图片',
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: .9),
                        width: 1.5,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(15),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => openImportPanel(context),
                        child: Center(
                          child: Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 22,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
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
                            : scheme.outline.withValues(alpha: .9),
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
                            onPressed: () {
                              _hintDisabledVibes(context, ref);
                              ref
                                  .read(generationProvider.notifier)
                                  .generate();
                            },
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

/// 生成/排队前置检查:缺当前模型编码的纯编码 Vibe 无从现场编码,
/// 只会被静默跳过——直接停用并提示,别让人误以为它生效了。
void _hintDisabledVibes(BuildContext context, WidgetRef ref) {
  final n = ref.read(generateProvider.notifier).disableVibesMissingEncoding();
  if (n > 0) {
    hintSnack(
      context,
      '$n 个 Vibe 缺当前模型编码,已停用',
      icon: Icons.visibility_off_outlined,
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
            backgroundColor: scheme.surfaceContainerHighest,
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
      color: scheme.surfaceContainerHighest,
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
