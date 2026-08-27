import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/nai_tokenizer.dart';
import '../../../core/util/prompt_convert.dart';
import '../../editor/editor_page.dart';
import '../generate_state.dart';
import '../models.dart' show tokenLimitOf;
import '../prompt_presets.dart';
import 'common.dart';

/// 提示词卡:头部 token 进度条 + 展开后完整显示正/负向提示词。
/// 头部右侧为「清空正向」、正/负提示词下划线转空格(均可撤销)与展开/收起。
class PromptCard extends ConsumerStatefulWidget {
  const PromptCard({super.key});

  @override
  ConsumerState<PromptCard> createState() => _PromptCardState();
}

class _PromptCardState extends ConsumerState<PromptCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    // web totalTokenCount 口径:主串 + 启用角色串 + 激活预设(都实际参与生成)。
    // 角色串取 countedCharactersProvider —— 模块不可见(anima 等)时为空,
    // 不然会出现「切到 anima 计数凭空变大」的幽灵。
    final tok = ref.watch(naiTokenizerProvider).value;
    final preset = ref.watch(promptPresetsProvider).value?.active;
    final chars = ref.watch(countedCharactersProvider);
    final promptTokens = totalPromptTokens(
      tok,
      main: state.prompt,
      parts: [for (final c in chars) c.positive],
      preset: preset?.positive ?? '',
    );
    final negTokens = totalPromptTokens(
      tok,
      main: state.negativePrompt,
      parts: [for (final c in chars) c.negative],
      preset: preset?.negative ?? '',
    );
    // 上限按当前模型取(NAI 5 抬到 703/1471,其余 512),读数与编辑器顶栏同源。
    final limit = tokenLimitOf(state.params.model);
    final over = promptTokens > limit;
    final ratio = (promptTokens / limit).clamp(0.0, 1.0);
    final barColor = over ? scheme.error : scheme.primary;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 8, 13, 4),
            child: Row(
              children: [
                Icon(Icons.subject, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 9),
                Text(
                  '提示词',
                  style: context.texts.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  '$promptTokens',
                  style: mono(
                    context,
                    size: 11,
                    weight: FontWeight.w700,
                  ).copyWith(color: over ? scheme.error : scheme.onSurface),
                ),
                Text(
                  ' / $limit',
                  style: mono(
                    context,
                    size: 11,
                    weight: FontWeight.w500,
                  ).copyWith(color: scheme.outline),
                ),
                const Spacer(),
                RoundIconBtn(
                  Icons.delete_sweep_outlined,
                  tooltip: '清空正向提示词',
                  color: scheme.onSurfaceVariant,
                  onTap: () {
                    final old = state.prompt;
                    if (old.isEmpty) return;
                    notifier.setPrompts(positive: '');
                    hintSnack(
                      context,
                      '已清空正向提示词',
                      icon: Icons.delete_sweep_outlined,
                      actionLabel: '撤销',
                      onAction: () => notifier.setPrompts(positive: old),
                    );
                  },
                ),
                const SizedBox(width: 6),
                RoundIconBtn(
                  Icons.space_bar_outlined,
                  tooltip: '下划线替换为空格',
                  color: scheme.onSurfaceVariant,
                  onTap: () {
                    final oldPositive = state.prompt;
                    final oldNegative = state.negativePrompt;
                    final positive = replacePromptUnderscores(oldPositive);
                    final negative = replacePromptUnderscores(oldNegative);
                    if (positive == oldPositive && negative == oldNegative) {
                      return;
                    }
                    final count =
                        '_'.allMatches(oldPositive).length +
                        '_'.allMatches(oldNegative).length;
                    notifier.setPrompts(positive: positive, negative: negative);
                    hintSnack(
                      context,
                      '已将 $count 个下划线替换为空格',
                      icon: Icons.space_bar_outlined,
                      actionLabel: '撤销',
                      onAction: () => notifier.setPrompts(
                        positive: oldPositive,
                        negative: oldNegative,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: _expanded ? '收起提示词' : '展开提示词',
                  child: InkResponse(
                    key: const ValueKey('prompt_expand_button'),
                    radius: 22,
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: SizedBox.square(
                      dimension: 36,
                      child: AnimatedRotation(
                        turns: _expanded ? .5 : 0,
                        duration: Motion.medium,
                        curve: Motion.emphasized,
                        child: Icon(
                          Icons.expand_more,
                          size: 22,
                          color: scheme.outline,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ExpandBody(
            expanded: _expanded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // token 用量进度条
                Padding(
                  padding: const EdgeInsets.fromLTRB(15, 0, 15, 2),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: ratio, end: ratio),
                      duration: Motion.medium,
                      builder: (_, v, _) => LinearProgressIndicator(
                        value: v,
                        minHeight: 3,
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: barColor,
                      ),
                    ),
                  ),
                ),
                // 正面:展开后按内容完整撑高。
                InkWell(
                  onTap: () => _openEditor(context, positive: true),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(15, 12, 15, 10),
                    child: Text(
                      state.prompt.isEmpty ? '点击编辑正面提示词…' : state.prompt,
                      style: context.texts.bodyLarge!.copyWith(
                        height: 1.5,
                        color: state.prompt.isEmpty
                            ? scheme.outline
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                // 负面:展开后同样完整显示,右侧保留独立 token 计数。
                InkWell(
                  onTap: () => _openEditor(context, positive: false),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(15, 6, 15, 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.block, size: 17, color: scheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            state.negativePrompt.isEmpty
                                ? '点击编辑负面提示词…'
                                : state.negativePrompt,
                            style: context.texts.bodyMedium!.copyWith(
                              height: 1.5,
                              color: scheme.error,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$negTokens',
                          style: mono(
                            context,
                            size: 12,
                            weight: FontWeight.w500,
                          ).copyWith(color: scheme.outline),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openEditor(BuildContext context, {required bool positive}) {
    Navigator.of(context).push(sharedAxisRoute(EditorPage(positive: positive)));
  }
}
