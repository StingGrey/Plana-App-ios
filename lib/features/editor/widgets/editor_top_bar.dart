import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/nai_tokenizer.dart';
import '../../generate/generate_state.dart';
import '../../generate/models.dart' show tokenLimitOf;
import '../../generate/prompt_presets.dart';
import '../../generate/prompt_sections.dart' show mainEnabled, sectionTexts;
import '../editor_state.dart';

/// 编辑器顶栏(精简):返回(=保存并退出)+ token 读数 + 文本整理 + 设置 + 满宽进度条。
/// 正/负 tab、撤销、纯文本切换都下放到底栏。整栏固定不滚。
class EditorTopBar extends ConsumerWidget {
  const EditorTopBar({
    super.key,
    required this.onBack,
    required this.onSettings,
    this.onReplaceUnderscores,
    this.charName,
    this.character = false,
    this.sectionId,
  });

  final VoidCallback onBack;
  final VoidCallback onSettings;
  final VoidCallback? onReplaceUnderscores;

  /// 标题:角色名 / 分区名;没分区的主提示词会话为 null,标题位留空。
  final String? charName;

  /// 角色会话:读数只计本角色正文。
  final bool character;

  /// 分区会话:读数照主提示词的口径算总数,这一格用编辑器里的实时文本。
  final String? sectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final st = ref.watch(editorProvider);

    // 主提示词(含分区)会话按 web totalTokenCount 口径计:正文 + 启用分区 +
    // 启用角色串 + 激活预设(都实际参与生成),与生成页卡头读数一致;
    // 角色会话只计本角色正文。
    final tok = ref.watch(naiTokenizerProvider).value;
    final preset = character ? null : ref.watch(activePromptPresetProvider);
    final presetSide = preset == null
        ? ''
        : (st.activePositive ? preset.positive : preset.negative);
    final gen = character
        ? null
        : ref.watch(
            generateProvider.select(
              (s) => (
                prompt: s.prompt,
                negative: s.negativePrompt,
                sections: s.sections,
              ),
            ),
          );
    // 主体的正向停用了就不算(负面那侧一直算,同出图)
    final mainOn =
        gen == null || !st.activePositive || mainEnabled(gen.sections);
    final parts = gen == null
        ? const <String>[]
        : [
            // 分区会话:编辑器里是这一格,主体换成存着的那份
            if (sectionId != null && mainOn)
              st.activePositive ? gen.prompt : gen.negative,
            ...sectionTexts(
              gen.sections,
              positive: st.activePositive,
              except: sectionId,
            ),
            // 与生成页同一口径:模块不可见(anima 等)时角色整组不计
            for (final c in ref.watch(countedCharactersProvider))
              st.activePositive ? c.positive : c.negative,
          ];
    // activeOutput 而非 outputOf(activeText):正文里折叠只是占位符 `#名字`,
    // 直接算会把整段折叠体漏掉——读数得按占位符展开后的真实定稿来。
    final tokens = totalPromptTokens(
      tok,
      main: sectionId == null && !mainOn ? '' : st.activeOutput,
      parts: parts,
      preset: presetSide,
    );
    // 上限按当前模型取(NAI 5 抬到 703/1471,其余 512),与生成页卡头同源。
    final limit = tokenLimitOf(
      ref.watch(generateProvider.select((s) => s.params.model)),
    );
    final over = tokens > limit;
    final ratio = (tokens / limit).clamp(0.0, 1.0);
    final barColor = over ? scheme.error : scheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                tooltip: '保存并返回',
              ),
              // 标题位兼作弹性占位:主提示词会话为空,视觉与从前的 Spacer 一致
              Expanded(
                child: charName == null
                    ? const SizedBox.shrink()
                    : Text(
                        charName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleSmall!.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
              Text(
                '$tokens',
                style: mono(
                  context,
                  size: 15,
                  weight: FontWeight.w700,
                ).copyWith(color: over ? scheme.error : scheme.onSurface),
              ),
              Text(
                ' / $limit',
                style: mono(
                  context,
                  size: 12,
                  weight: FontWeight.w500,
                ).copyWith(color: scheme.outline),
              ),
              const SizedBox(width: 2),
              IconButton(
                onPressed: onReplaceUnderscores,
                icon: const Icon(Icons.space_bar_outlined, size: 22),
                tooltip: '下划线替换为空格',
              ),
              IconButton(
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined, size: 22),
                tooltip: '编辑器设置',
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
