import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/prompt_presets.dart';
import '../editor_models.dart';
import '../editor_state.dart';

/// 编辑器顶栏(精简):返回(=保存并退出)+ token 读数 + 满宽进度条。
/// 正/负 tab、撤销、纯文本切换都下放到底栏。整栏固定不滚。
class EditorTopBar extends ConsumerWidget {
  const EditorTopBar({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final st = ref.watch(editorProvider);

    // 激活预设按当前正/负侧计入(预设实际参与生成,上限显示要含它)
    final preset = ref.watch(promptPresetsProvider).value?.active;
    final presetSide = preset == null
        ? ''
        : (st.activePositive ? preset.positive : preset.negative);
    final tokens = estimateTokensWithPreset(
      outputOf(st.activeText),
      presetSide,
    );
    final over = tokens > 512;
    final ratio = (tokens / 512).clamp(0.0, 1.0);
    final barColor = over ? scheme.error : scheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 16, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                tooltip: '保存并返回',
              ),
              const Spacer(),
              Text(
                '$tokens',
                style: mono(
                  context,
                  size: 15,
                  weight: FontWeight.w700,
                ).copyWith(color: over ? scheme.error : scheme.onSurface),
              ),
              Text(
                ' / 512',
                style: mono(
                  context,
                  size: 12,
                  weight: FontWeight.w500,
                ).copyWith(color: scheme.outline),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: ratio, end: ratio),
              duration: Motion.medium,
              curve: Motion.standard,
              builder: (_, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 4,
                backgroundColor: scheme.surfaceContainerHighest,
                color: barColor,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
