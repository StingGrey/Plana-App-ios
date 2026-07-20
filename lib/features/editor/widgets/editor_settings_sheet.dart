import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../editor_settings.dart';

/// 编辑器设置弹层:行为开关 + 档位选择,改动即时生效并持久化。
/// 按模块分组;子项跟随所属功能开关置灰(补全关了实体/逗号无意义)。
class EditorSettingsSheet extends ConsumerWidget {
  const EditorSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final s = ref.watch(editorSettingsProvider).value ?? const EditorSettings();
    final notifier = ref.read(editorSettingsProvider.notifier);

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewPaddingOf(context).bottom + 10,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.outline.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                child: Text(
                  '编辑器设置',
                  style: context.texts.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _sectionLabel(context, '显示'),
              _SettingRow(
                icon: Icons.translate,
                title: '显示注释翻译',
                desc: '在词条下方以小字标注中文翻译',
                value: s.showTranslation,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(showTranslation: v)),
              ),
              _SettingRow(
                icon: Icons.format_color_fill,
                title: '权重高亮',
                desc: '加权 / 降权词条按强度显示红 / 蓝色',
                value: s.showWeightWash,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(showWeightWash: v)),
              ),
              _ChoiceRow<double>(
                icon: Icons.format_size,
                title: '编辑器字号',
                desc: '正文字号,注音与排版同步',
                options: const [(14.0, '小'), (16.0, '标准'), (18.0, '大')],
                value: s.fontSize,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(fontSize: v)),
              ),
              _ChoiceRow<double>(
                icon: Icons.report_gmailerrorred,
                title: '异常权重阈值',
                desc: '词条中段 ≥ 此值的「N::」标红警示',
                options: const [(3.0, '3'), (5.0, '5'), (10.0, '10')],
                optWidth: 38,
                value: s.abnormalThreshold,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(abnormalThreshold: v)),
              ),
              _sectionLabel(context, '补全'),
              _SettingRow(
                icon: Icons.manage_search,
                title: '启用补全提示',
                desc: '输入时在底部给出标签补全建议',
                value: s.enableCompletion,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(enableCompletion: v)),
              ),
              _SettingRow(
                icon: Icons.category_outlined,
                title: '实体建议',
                desc: '补全中包含画师 / 角色 / OC / 作品',
                value: s.entitySuggest,
                enabled: s.enableCompletion,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(entitySuggest: v)),
              ),
              _SettingRow(
                icon: Icons.auto_fix_high,
                title: '选词自动补逗号',
                desc: '选中补全后自动加「, 」,方便连打下一枚',
                value: s.autoComma,
                enabled: s.enableCompletion,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(autoComma: v)),
              ),
              _sectionLabel(context, '词条栏'),
              _SettingRow(
                icon: Icons.sell_outlined,
                title: '启用标签面板',
                desc: '光标停在词条上时显示权重与操作栏',
                value: s.enableTagPanel,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(enableTagPanel: v)),
              ),
              _ChoiceRow<double>(
                icon: Icons.exposure,
                title: '权重步进',
                desc: '数值 +/− 每步的调整量',
                options: const [
                  (0.05, '0.05'),
                  (0.1, '0.1'),
                  (0.2, '0.2'),
                  (0.5, '0.5'),
                ],
                // 4 段:用默认 48 宽会挤到左侧标题,收到 40 刚好容下「0.05」
                optWidth: 40,
                value: s.weightStep,
                enabled: s.enableTagPanel,
                onChanged: (v) =>
                    notifier.patch((c) => c.copyWith(weightStep: v)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
      child: Text(
        text,
        style: context.texts.labelSmall!.copyWith(
          color: context.scheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 单行开关:整行可点,图标随开关着色;[enabled]=false 时整行淡显不可点。
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.desc,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String desc;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  void _flip(bool v) {
    HapticFeedback.selectionClick();
    onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return InkWell(
      onTap: enabled ? () => _flip(!value) : null,
      child: AnimatedOpacity(
        duration: Motion.fast,
        opacity: enabled ? 1 : .42,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 14, 8),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: value ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _RowTexts(title: title, desc: desc),
              ),
              const SizedBox(width: 8),
              Switch(value: value, onChanged: enabled ? _flip : null),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单行档位选择:左侧标题说明,右侧滑块分段。
class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.icon,
    required this.title,
    required this.desc,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.optWidth = 48,
  });

  final IconData icon;
  final String title;
  final String desc;
  final List<(T, String)> options;
  final T value;
  final bool enabled;
  final ValueChanged<T> onChanged;

  /// 单段宽度(短数字标签的 4 段行可收窄防挤压)。
  final double optWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return AnimatedOpacity(
      duration: Motion.fast,
      opacity: enabled ? 1 : .42,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: _RowTexts(title: title, desc: desc),
            ),
            const SizedBox(width: 8),
            IgnorePointer(
              ignoring: !enabled,
              child: _MiniSeg<T>(
                options: options,
                value: value,
                optWidth: optWidth,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowTexts extends StatelessWidget {
  const _RowTexts({required this.title, required this.desc});

  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: context.texts.bodyLarge!.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          desc,
          style: context.texts.labelSmall!.copyWith(
            color: context.scheme.outline,
          ),
        ),
      ],
    );
  }
}

/// 紧凑滑块分段(与 App 内其他分段切换同款物理:滑块滑动 + 文字渐变)。
class _MiniSeg<T> extends StatelessWidget {
  const _MiniSeg({
    required this.options,
    required this.value,
    required this.onChanged,
    this.optWidth = 48,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final double optWidth;

  static const double _h = 28;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    var idx = options.indexWhere((o) => o.$1 == value);
    if (idx < 0) idx = 0;

    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
      ),
      child: SizedBox(
        width: optWidth * options.length,
        height: _h,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: Motion.medium,
              curve: Motion.emphasized,
              left: idx * optWidth,
              top: 0,
              bottom: 0,
              width: optWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
            Row(
              children: [
                for (final (v, label) in options)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (v == value) return;
                      HapticFeedback.selectionClick();
                      onChanged(v);
                    },
                    child: SizedBox(
                      width: optWidth,
                      height: _h,
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: Motion.medium,
                          curve: Motion.standard,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: v == value
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: v == value
                                ? scheme.onPrimary
                                : scheme.onSurfaceVariant,
                          ),
                          child: Text(label),
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
