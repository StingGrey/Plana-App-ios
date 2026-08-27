import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../anima_nl.dart';
import '../generate_state.dart';
import '../models.dart';
import 'common.dart';
import 'section_card.dart';

/// 自然语言卡(anima 专属模块,对齐 web AnimaNlModule):
/// 两个预设一键让 AI 按当前正向词写英文句子,一次结果就是一整段,
/// 点一下整段写进正向词(再点一下整段移出)——一个插入点。
///
/// ⚠ krea 有一张同名卡([KreaPromptCard]),行为相反:那边产的是整条新的正向词、
/// 动作是替换/还原。同名是用户定的(对用户而言就是同一件事:让 AI 写自然语言),
/// 改代码时按 provider 认卡,别按名字。
class AnimaNlCard extends ConsumerStatefulWidget {
  const AnimaNlCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  ConsumerState<AnimaNlCard> createState() => _AnimaNlCardState();
}

class _AnimaNlCardState extends ConsumerState<AnimaNlCard> {
  late final TextEditingController _extra = TextEditingController(
    text: ref.read(animaNlProvider).value?.extra ?? '',
  );

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  /// 整段 ↔ 正向词(唯一插入点)。写入方只动定稿(同 LoRA 触发词/画师串),
  /// 编辑器草稿作废。
  void _toggle(String text) {
    final notifier = ref.read(generateProvider.notifier);
    final cur = ref.read(generateProvider).prompt;
    notifier.setPrompts(
      positive: promptHasNl(cur, text)
          ? removeNlFromPrompt(cur, text)
          : appendNlToPrompt(cur, text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final st = ref.watch(animaNlProvider).value ?? const AnimaNlState();
    final notifier = ref.read(animaNlProvider.notifier);
    // 存档是异步水合的:建控件时可能还没读到,回来了要补进输入框
    // (不然框里空着、发请求却带着上次存的补充要求)。用户打字时两边恒等,不会打架。
    ref.listen(animaNlProvider, (_, next) {
      final extra = next.value?.extra ?? '';
      if (_extra.text == extra) return;
      _extra.value = TextEditingValue(
        text: extra,
        selection: TextSelection.collapsed(offset: extra.length),
      );
    });
    final prompt = ref.watch(generateProvider.select((s) => s.prompt));
    final expanded = ref.watch(
      generateProvider.select((s) => s.openPanels.contains(Panel.animaNl)),
    );

    final full = st.fullText;
    final applied = full.isNotEmpty && promptHasNl(prompt, full);
    final busy = st.running != null;

    return SectionCard(
      icon: Icons.format_align_left,
      title: '自然语言',
      reorderIndex: widget.reorderIndex,
      // 收起时也答得上「这次带没带这段」——同重绘放大卡头报目标尺寸
      inline: [
        if (applied)
          Text(
            '已写入',
            style: context.texts.labelMedium!.copyWith(color: scheme.primary),
          ),
      ],
      expanded: expanded,
      onHeaderTap: () =>
          ref.read(generateProvider.notifier).togglePanel(Panel.animaNl),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final m in AnimaNlMode.values) ...[
                Expanded(
                  child: _PresetButton(
                    icon: m == AnimaNlMode.characters
                        ? Icons.groups_outlined
                        : Icons.auto_fix_high_outlined,
                    label: m.label,
                    running: st.running == m,
                    onTap: busy ? null : () => notifier.run(m),
                  ),
                ),
                if (m != AnimaNlMode.values.last) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _extra,
            onChanged: notifier.setExtra,
            maxLines: 2,
            minLines: 1,
            style: context.texts.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHigh.withValues(alpha: .5),
              hintText: '补充要求(可选)· 例:强调雨天湿透的质感',
              hintStyle: context.texts.bodySmall!.copyWith(
                color: scheme.outline,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          if (busy) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI 正在写句子…',
                    style: context.texts.labelMedium!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(onPressed: notifier.cancel, child: const Text('取消')),
              ],
            ),
          ],
          if (st.error.isNotEmpty && !busy) ...[
            const SizedBox(height: 10),
            InfoNote(st.error, icon: Icons.error_outline, color: scheme.error),
          ],
          if (full.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '点击写入/移出正向提示词',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
                RoundIconBtn(
                  Icons.refresh,
                  size: 30,
                  iconSize: 17,
                  tooltip: '换个角度重写',
                  color: scheme.onSurfaceVariant,
                  onTap: busy || st.mode == null
                      ? null
                      : () => notifier.run(st.mode!),
                ),
                const SizedBox(width: 4),
                RoundIconBtn(
                  Icons.delete_outline,
                  size: 30,
                  iconSize: 17,
                  tooltip: '清空结果(不动已写进正向词的句子)',
                  color: scheme.onSurfaceVariant,
                  onTap: notifier.clearResult,
                ),
              ],
            ),
            if (st.result!.noteZh.isNotEmpty) ...[
              const SizedBox(height: 8),
              InfoNote(st.result!.noteZh),
            ],
            const SizedBox(height: 8),
            _FullTextBlock(
              text: full,
              added: applied,
              onTap: () => _toggle(full),
            ),
          ],
        ],
      ),
    );
  }
}

/// 预设按钮:跑着的那个就地转圈(不整卡遮罩),另一个同时置灰。
class _PresetButton extends StatelessWidget {
  const _PresetButton({
    required this.icon,
    required this.label,
    required this.running,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool running;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return FilledButton.tonalIcon(
      onPressed: onTap,
      icon: running
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onSecondaryContainer,
              ),
            )
          : Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: context.texts.labelLarge,
      ),
    );
  }
}

/// 这次结果的一整段,整块可点(已在场则 ✓,再点整段移出)——一次结果一个插入点。
class _FullTextBlock extends StatelessWidget {
  const _FullTextBlock({
    required this.text,
    required this.added,
    required this.onTap,
  });

  final String text;
  final bool added;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: added
          ? scheme.primary.withValues(alpha: .13)
          : scheme.surfaceContainerHigh.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(9),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: added
                  ? scheme.primary.withValues(alpha: .5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                added ? Icons.check : Icons.add,
                size: 14,
                color: added ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  text,
                  style: context.texts.bodySmall!.copyWith(
                    height: 1.45,
                    color: added ? scheme.primary : scheme.onSurfaceVariant,
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
