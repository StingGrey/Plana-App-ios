import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../generate_state.dart';
import '../krea_prompt.dart';
import '../models.dart';
import 'common.dart';
import 'section_card.dart';

/// 自然语言卡(krea 专属模块,对齐 web KreaPromptModule):
/// 两个预设一键让 AI 把当前正向词整条改写成一段 k2 提示词。
///
/// ⚠ anima 有一张**同名**卡([AnimaNlCard]),长得像但行为相反,改代码时别串
/// (同名是用户定的:对用户而言就是同一件事,让 AI 写自然语言):
///   anima  产的是补充段落 → 整段写进/移出正向词末尾(一个插入点,天然可逆)
///   krea   产的是整条新正向词 → **替换**原文,原文存一份供还原
/// 所以这里的结果块是只读预览,动作是底下那颗「替换 / 还原」按钮。
class KreaPromptCard extends ConsumerStatefulWidget {
  const KreaPromptCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  ConsumerState<KreaPromptCard> createState() => _KreaPromptCardState();
}

class _KreaPromptCardState extends ConsumerState<KreaPromptCard> {
  late final TextEditingController _extra = TextEditingController(
    text: ref.read(kreaPromptProvider).value?.extra ?? '',
  );

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final st = ref.watch(kreaPromptProvider).value ?? const KreaPromptState();
    final notifier = ref.read(kreaPromptProvider.notifier);
    // 存档是异步水合的:建控件时可能还没读到,回来了要补进输入框
    // (不然框里空着、发请求却带着上次存的补充要求)。用户打字时两边恒等,不会打架。
    ref.listen(kreaPromptProvider, (_, next) {
      final extra = next.value?.extra ?? '';
      if (_extra.text == extra) return;
      _extra.value = TextEditingValue(
        text: extra,
        selection: TextSelection.collapsed(offset: extra.length),
      );
    });
    final prompt = ref.watch(generateProvider.select((s) => s.prompt));
    final expanded = ref.watch(
      generateProvider.select((s) => s.openPanels.contains(Panel.kreaPrompt)),
    );

    final full = st.fullText;
    // 替换后又编辑过就不再给还原:那时候还原等于把用户的修改毁掉
    final replaced = st.replacedIn(prompt);
    final busy = st.running != null;

    return SectionCard(
      icon: Icons.format_align_left,
      title: '自然语言',
      reorderIndex: widget.reorderIndex,
      // 收起时也答得上「正向词是不是这张卡换过的」
      inline: [
        if (replaced)
          Text(
            '已替换',
            style: context.texts.labelMedium!.copyWith(color: scheme.primary),
          ),
      ],
      expanded: expanded,
      onHeaderTap: () =>
          ref.read(generateProvider.notifier).togglePanel(Panel.kreaPrompt),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final m in KreaPromptMode.values) ...[
                Expanded(
                  child: _PresetButton(
                    icon: m == KreaPromptMode.rewrite
                        ? Icons.format_align_left
                        : Icons.auto_fix_high_outlined,
                    label: m.label,
                    running: st.running == m,
                    onTap: busy ? null : () => notifier.run(m),
                  ),
                ),
                if (m != KreaPromptMode.values.last) const SizedBox(width: 8),
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
              hintText: '补充要求(可选)· 例:改成黄昏的暖光',
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
                    'AI 正在整理…',
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
                    replaced ? '已替换正向提示词' : '整理结果',
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
                RoundIconBtn(
                  Icons.refresh,
                  size: 30,
                  iconSize: 17,
                  tooltip: '重新整理一次',
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
                  tooltip: '清空结果(不动提示词框里的内容)',
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
            // 只读预览:先看清楚再决定替不替换(anima 那张是点一下就写进去,
            // 因为它可逆;这张一按就盖掉整条正向词,得先给人看)
            Container(
              constraints: const BoxConstraints(maxHeight: 168),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(9),
              ),
              child: SingleChildScrollView(
                child: Text(
                  full,
                  style: context.texts.bodySmall!.copyWith(
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            replaced
                ? OutlinedButton.icon(
                    onPressed: notifier.restore,
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('还原成替换前'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                    ),
                  )
                : FilledButton.tonalIcon(
                    onPressed: notifier.applyReplace,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('替换正向提示词'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                    ),
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
