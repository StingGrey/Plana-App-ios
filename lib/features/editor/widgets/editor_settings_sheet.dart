import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../editor_settings.dart';
import '../prompt_blacklist.dart';
import '../../../core/util/haptics.dart';
import 'tag_panel.dart' show RepeatBtn;

/// 编辑器设置弹层:行为开关 + 档位选择 + 加减调节,改动即时生效并持久化。
/// 按模块分组;子项跟随所属功能开关置灰(补全关了实体/逗号无意义)。
class EditorSettingsSheet extends ConsumerWidget {
  const EditorSettingsSheet({super.key});

  /// 正文之上那一坨固定高度:顶栏 72(返回行 54 + token 进度条 18)
  /// + 正文区自己的上内边距 8。
  static const _kChromeH = 80.0;

  /// 弹层上方要露出的正文行数 × 默认行高(字号 16 × 行高 2.0)。
  static const _kPeek = 2 * 32.0;

  /// 弹层封顶高度:**不顶满**,上面留出顶栏和两行正文。
  ///
  /// 字号、注音翻译、权重高亮这几项改的就是「正文长什么样」,把正文遮死了
  /// 只能关掉看一眼、再开、再调 —— 露两行就能边调边看。
  ///
  /// 按绝对高度扣而不是按屏高取百分比:要留的是「顶栏 + 两行字」这个**固定**
  /// 的量,屏幕越高百分比越不准。两头夹一下防极端屏幕。
  ///
  /// ⚠ 状态栏高度**不能**读 `MediaQuery.viewPaddingOf(context)`:
  /// ModalBottomSheetRoute 内部做过 `removePadding(removeTop: true)`,
  /// 弹层里读到的顶部安全区恒为 0 —— 少扣一整个状态栏,正文就只剩半行(踩过)。
  /// 直接问 View 拿原始 insets。
  static double _maxHeight(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final top = MediaQueryData.fromView(View.of(context)).padding.top;
    return (h - top - _kChromeH - _kPeek).clamp(h * .5, h * .85);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final s = ref.watch(editorSettingsProvider).value ?? const EditorSettings();
    final notifier = ref.read(editorSettingsProvider.notifier);

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: _maxHeight(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抓手与标题栏留在滚动区**外面**:整片都塞进 SingleChildScrollView
            // 的话,下拉手势全被滚动条吃掉,弹层自带的下拉关闭永远轮不到
            // (真机反馈:拉不动也没地方点关)。右侧再给一个 ✕ 兜底。
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
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '编辑器设置',
                      style: context.texts.titleMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom + 10,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                    _StepperRow(
                      icon: Icons.format_size,
                      title: '文本字号',
                      desc: '文本模式下的文本显示大小',
                      value: s.fontSize,
                      min: EditorSettings.fontSizeMin,
                      max: EditorSettings.fontSizeMax,
                      step: EditorSettings.fontSizeStep,
                      format: (v) => v.toStringAsFixed(0),
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(fontSize: v)),
                    ),
                    _StepperRow(
                      icon: Icons.label_outline,
                      title: '芯片字号',
                      desc: '芯片模式下的芯片显示大小',
                      value: s.chipFontSize,
                      min: EditorSettings.fontSizeMin,
                      max: EditorSettings.fontSizeMax,
                      step: EditorSettings.fontSizeStep,
                      format: (v) => v.toStringAsFixed(0),
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(chipFontSize: v)),
                    ),
                    _sectionLabel(context, '补全'),
                    _SettingRow(
                      icon: Icons.manage_search,
                      title: '启用补全提示',
                      desc: '输入时在底部给出标签补全建议',
                      value: s.enableCompletion,
                      onChanged: (v) => notifier.patch(
                        (c) => c.copyWith(enableCompletion: v),
                      ),
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
                    _SettingRow(
                      icon: Icons.density_small,
                      title: '精简词条栏',
                      desc: '压成一行,只留权重与删除,正文多露两行',
                      value: s.compactTagPanel,
                      enabled: s.enableTagPanel,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(compactTagPanel: v)),
                    ),
                    _StepperRow(
                      icon: Icons.exposure,
                      title: '权重步进',
                      desc: '数值 +/− 每步的调整量',
                      value: s.weightStep,
                      min: EditorSettings.weightStepMin,
                      max: EditorSettings.weightStepMax,
                      step: EditorSettings.weightStepTick,
                      format: _fmtStep,
                      enabled: s.enableTagPanel,
                      onChanged: (v) =>
                          notifier.patch((c) => c.copyWith(weightStep: v)),
                    ),
                    _sectionLabel(context, '过滤'),
                    _ChoiceRow<PromptBlacklistMode>(
                      icon: Icons.rule_rounded,
                      title: '黑名单处理',
                      desc: s.promptBlacklistMode == PromptBlacklistMode.remove
                          ? '命中后立即删除完整标签'
                          : '保留并标红，可在编辑器中一键删除',
                      options: const [
                        (PromptBlacklistMode.remove, '自动删'),
                        (PromptBlacklistMode.highlight, '标红'),
                      ],
                      optWidth: 58,
                      value: s.promptBlacklistMode,
                      onChanged: (v) => notifier.patch(
                        (c) => c.copyWith(promptBlacklistMode: v),
                      ),
                    ),
                    _ActionRow(
                      icon: Icons.block_outlined,
                      title: '提示词黑名单',
                      desc: s.promptBlacklist.isEmpty
                          ? '未设置；支持完整标签与 /.../ 正则'
                          : '已设置 ${s.promptBlacklist.length} 条规则；空格与下划线等价',
                      onTap: () => _editPromptBlacklist(
                        context,
                        notifier,
                        s.promptBlacklist,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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

  Future<void> _editPromptBlacklist(
    BuildContext context,
    EditorSettingsNotifier notifier,
    List<String> current,
  ) async {
    final controller = TextEditingController(
      text: promptBlacklistText(current),
    );
    final raw = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('提示词黑名单'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '每行一条，也可用逗号分隔。普通词按完整标签匹配，'
                '忽略大小写，空格与下划线视为相同。/penis/ '
                '这种写法为正则；正则命中子串后仍处理逗号之间的整枚标签。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 5,
                maxLines: 9,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: '例如：\nhuge penis\n/penis/\nwatermark',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null) return;
    await notifier.patch(
      (settings) =>
          settings.copyWith(promptBlacklist: parsePromptBlacklistText(raw)),
    );
  }
}

/// 无开关的设置入口:点整行进入编辑页/对话框。
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
            Expanded(child: _RowTexts(title: title, desc: desc)),
            const SizedBox(width: 8),
            IgnorePointer(
              ignoring: !enabled,
              child: SegmentedButton<T>(
                segments: [
                  for (final option in options)
                    ButtonSegment<T>(
                      value: option.$1,
                      label: SizedBox(
                        width: optWidth,
                        child: Text(option.$2, textAlign: TextAlign.center),
                      ),
                    ),
                ],
                selected: {value},
                onSelectionChanged: (values) => onChanged(values.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.desc,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String desc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Haptics.selection();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 14, 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: context.scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: _RowTexts(title: title, desc: desc),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: context.scheme.outline),
          ],
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
    Haptics.selection();
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

/// 权重步进读数:两位小数去掉尾随的零(0.10 → 0.1,0.05 原样)。
/// 一列读数里只有它拖着个空转的小数位会很扎眼。
String _fmtStep(double v) {
  var t = v.toStringAsFixed(2);
  if (t.contains('.')) {
    t = t.replaceFirst(RegExp(r'0+$'), '');
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  }
  return t;
}

/// 加减调节行:左边图标+标题,右边一组 `− 读数 +`。
///
/// 为什么不是档位:字号、权重步进这类偏好没有天然的"三五个正确值" ——
/// 屏幕尺寸、视力、习惯的加权幅度各不相同,给了三档总有人卡在两档之间。
/// 按钮支持长按连发([RepeatBtn]),大范围也不用点几十下。
class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.icon,
    required this.title,
    required this.desc,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onChanged,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String desc;
  final double value;
  final double min;
  final double max;
  final double step;

  /// 读数怎么写(字号取整、步进去尾零)。
  final String Function(double) format;

  final bool enabled;
  final ValueChanged<double> onChanged;

  /// 按整数格数走再落回实数:直接 `value += step` 累加浮点误差,连点几十下
  /// 就会漂成 0.30000000000000004 这种,存进设置里再读出来更难看。
  void _bump(int dir) {
    final ticks = (value / step).round() + dir;
    final next = (ticks * step).clamp(min, max).toDouble();
    // 再夹一次到步长网格上,顺便把二进制小数的零头抹掉
    final snapped = double.parse(next.toStringAsFixed(4));
    if (snapped == value) return;
    Haptics.selection();
    onChanged(snapped);
  }

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
              child: Row(
                children: [
                  RepeatBtn(
                    icon: Icons.remove,
                    size: 32,
                    enabled: enabled && value > min,
                    step: () => _bump(-1),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      format(value),
                      textAlign: TextAlign.center,
                      style: mono(context, size: 15, weight: FontWeight.w700),
                    ),
                  ),
                  RepeatBtn(
                    icon: Icons.add,
                    size: 32,
                    enabled: enabled && value < max,
                    step: () => _bump(1),
                  ),
                ],
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
