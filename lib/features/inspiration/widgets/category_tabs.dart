import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 灵感页顶栏的分类页签:大字横排、可横滑,选中项加粗放大并带一道主色短线;
/// 行末固定一颗「类别管理」。换选中项时自动滚到可见。
class CategoryTabs extends StatefulWidget {
  const CategoryTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onTap,
    this.onManage,
    this.leftPad = 14,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onTap;

  /// null = 不出行末的「类别管理」。
  final VoidCallback? onManage;
  final double leftPad;

  @override
  State<CategoryTabs> createState() => _CategoryTabsState();
}

class _CategoryTabsState extends State<CategoryTabs> {
  final _keys = <GlobalKey>[];

  @override
  void didUpdateWidget(covariant CategoryTabs old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  void _reveal() {
    final i = widget.index;
    if (i < 0 || i >= _keys.length) return;
    final ctx = _keys[i].currentContext;
    if (ctx == null || !mounted) return;
    Scrollable.ensureVisible(
      ctx,
      duration: Motion.medium,
      curve: Motion.standard,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    Scrollable.ensureVisible(
      ctx,
      duration: Motion.medium,
      curve: Motion.standard,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    while (_keys.length < widget.labels.length) {
      _keys.add(GlobalKey());
    }
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(left: widget.leftPad - 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < widget.labels.length; i++)
                    _tab(context, i, scheme),
                ],
              ),
            ),
          ),
          // 固定在页签外面,页签再多也不会被挤到滚动区后头
          if (widget.onManage != null)
            IconButton(
              tooltip: '类别管理',
              onPressed: widget.onManage,
              icon: Icon(
                Icons.dashboard_customize_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, int i, ColorScheme scheme) {
    final sel = i == widget.index;
    return InkWell(
      key: _keys[i],
      borderRadius: BorderRadius.circular(10),
      onTap: () => widget.onTap(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            AnimatedDefaultTextStyle(
              duration: Motion.fast,
              curve: Motion.standard,
              style: context.texts.titleMedium!.copyWith(
                fontSize: sel ? 18 : 15,
                height: 1.2,
                fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                color: sel ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
              child: Text(widget.labels[i], maxLines: 1),
            ),
            const SizedBox(height: 5),
            AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.standard,
              width: sel ? 16 : 0,
              height: 3,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
