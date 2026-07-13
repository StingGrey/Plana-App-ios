import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../editor_models.dart';
import '../editor_state.dart';

/// 编辑器底栏:正/负 tab(左)+ 排序 + 撤销(右)。
/// 从顶栏下放到拇指易达的底部,吸在补全栏 / 键盘之上。
class EditorBottomBar extends ConsumerWidget {
  const EditorBottomBar({
    super.key,
    required this.onSort,
    required this.sortActive,
  });

  /// 排序模式开关;词条 <2 且未在模式中时禁用。
  final VoidCallback onSort;
  final bool sortActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final st = ref.watch(editorProvider);
    final notifier = ref.read(editorProvider.notifier);
    final sortable = sortActive || parseToks(st.activeText).length >= 2;

    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            _PosNegToggle(
              positive: st.activePositive,
              onChanged: notifier.setActivePositive,
            ),
            const Spacer(),
            _Pill(
              icon: Icons.swap_horiz,
              label: sortActive ? '完成' : '排序',
              enabled: sortable,
              selected: sortActive,
              onTap: onSort,
            ),
            const SizedBox(width: 8),
            _Pill(
              icon: Icons.undo,
              label: '撤销',
              enabled: st.canUndo,
              onTap: notifier.undo,
            ),
          ],
        ),
      ),
    );
  }
}

/// 操作药丸:图标 + 文案,禁用置灰,选中高亮(撤销/排序共用)。
class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fg = !enabled
        ? scheme.outlineVariant
        : selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: context.texts.bodyMedium!.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 正面 / 负面 切换 —— 滑块分段:激活段填充语义色(正面金 / 负面红)并滑动过渡。
class _PosNegToggle extends StatelessWidget {
  const _PosNegToggle({required this.positive, required this.onChanged});

  final bool positive;
  final ValueChanged<bool> onChanged;

  static const double _segW = 60;
  static const double _h = 36;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final thumbColor = positive ? scheme.primary : scheme.error;
    final onThumb = positive ? scheme.onPrimary : scheme.onError;

    return Container(
      // 定宽:Row 里宽度无界时 Align 会收缩到滑块自身,滑块没有可移动
      // 空间——永远停在左段、切换无动画(真机反馈修复)。
      width: _PosNegToggle._segW * 2 + 6,
      height: _h,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(_h / 2),
      ),
      child: Stack(
        children: [
          // 滑块:填充当前语义色,左右滑动
          AnimatedAlign(
            duration: Motion.medium,
            curve: Motion.emphasized,
            alignment: positive ? Alignment.centerLeft : Alignment.centerRight,
            child: AnimatedContainer(
              duration: Motion.medium,
              curve: Motion.standard,
              width: _segW,
              height: _h - 6,
              decoration: BoxDecoration(
                color: thumbColor,
                borderRadius: BorderRadius.circular((_h - 6) / 2),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _seg(
                '正面',
                Icons.check,
                active: positive,
                onThumb: onThumb,
                onTap: () => onChanged(true),
              ),
              _seg(
                '负面',
                Icons.block,
                active: !positive,
                onThumb: onThumb,
                onTap: () => onChanged(false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seg(
    String label,
    IconData icon, {
    required bool active,
    required Color onThumb,
    required VoidCallback onTap,
  }) {
    return _SegLabel(
      label: label,
      icon: icon,
      active: active,
      onThumb: onThumb,
      width: _segW,
      height: _h - 6,
      onTap: onTap,
    );
  }
}

class _SegLabel extends StatelessWidget {
  const _SegLabel({
    required this.label,
    required this.icon,
    required this.active,
    required this.onThumb,
    required this.width,
    required this.height,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final Color onThumb;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fg = active ? onThumb : scheme.onSurfaceVariant;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
