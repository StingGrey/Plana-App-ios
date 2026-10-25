import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/theme/app_theme.dart';

/// 灵感页顶栏的分类页签:一条连续的横滚标签,选中项放大加深、下面一道主色短线。
/// [position] 是正文翻页的位置(可在两页之间),短线和字跟着它过渡,标签条跟着滚,
/// 让当前项保持在中间。行末固定一颗「类别管理」。
class CategoryTabs extends StatefulWidget {
  const CategoryTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onTap,
    this.position,
    this.onManage,
    this.leftPad = 14,
  });

  final List<String> labels;

  /// 当前页签;[position] 还没有值时按它画。
  final int index;
  final ValueChanged<int> onTap;
  final ValueListenable<double>? position;

  /// null = 不出行末的「类别管理」。
  final VoidCallback? onManage;
  final double leftPad;

  @override
  State<CategoryTabs> createState() => _CategoryTabsState();
}

class _CategoryTabsState extends State<CategoryTabs> {
  static const _padH = 11.0;

  /// 选中项放大的比例。字号不变、只做缩放,页签宽度就是固定的,短线好对位。
  static const _grow = .2;

  final _scroll = ScrollController();
  final _stripKey = GlobalKey();
  final _keys = <GlobalKey>[];

  /// 各页签中心在标签条里的横坐标(量出来的);没量到之前不画短线。
  List<double> _centers = const [];

  /// 按翻页位置画;还没有位置时按 [CategoryTabs.index]。
  double get _pos {
    final p = widget.position?.value;
    if (p == null || widget.labels.isEmpty) return widget.index.toDouble();
    return p.clamp(0.0, widget.labels.length - 1.0);
  }

  @override
  void initState() {
    super.initState();
    widget.position?.addListener(_follow);
    _measureLater();
  }

  @override
  void didUpdateWidget(covariant CategoryTabs old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      old.position?.removeListener(_follow);
      widget.position?.addListener(_follow);
    }
    if (old.labels.join('\n') != widget.labels.join('\n')) _measureLater();
    if (old.index != widget.index) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _centerOn(_pos));
    }
  }

  void _follow() {
    if (!mounted) return;
    setState(() {});
    _centerOn(_pos);
  }

  void _measureLater() =>
      SchedulerBinding.instance.addPostFrameCallback((_) => _measure());

  void _measure() {
    if (!mounted) return;
    final strip = _stripKey.currentContext?.findRenderObject() as RenderBox?;
    if (strip == null || !strip.hasSize) return;
    final centers = <double>[];
    for (final k in _keys.take(widget.labels.length)) {
      final box = k.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      centers.add(
        box.localToGlobal(Offset(box.size.width / 2, 0), ancestor: strip).dx,
      );
    }
    setState(() => _centers = centers);
    _centerOn(_pos);
  }

  /// 位置 [p] 处(可在两个页签之间)的中心横坐标。
  double? _centerAt(double p) {
    if (_centers.isEmpty) return null;
    final c = p.clamp(0.0, _centers.length - 1.0);
    final i = c.floor(), j = c.ceil();
    return _centers[i] + (_centers[j] - _centers[i]) * (c - i);
  }

  void _centerOn(double p) {
    final x = _centerAt(p);
    if (x == null || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final target = (x + widget.leftPad - _padH - pos.viewportDimension / 2)
        .clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() > .5) _scroll.jumpTo(target);
  }

  @override
  void dispose() {
    widget.position?.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    while (_keys.length < widget.labels.length) {
      _keys.add(GlobalKey());
    }
    final pos = _pos;
    final x = _centerAt(pos);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(left: widget.leftPad - _padH, right: 4),
              child: Stack(
                key: _stripKey,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.labels.length; i++)
                        _tab(context, i, pos, scheme),
                    ],
                  ),
                  if (x != null)
                    Positioned(
                      left: x - 8,
                      bottom: 4,
                      child: Container(
                        width: 16,
                        height: 3,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
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

  Widget _tab(BuildContext context, int i, double pos, ColorScheme scheme) {
    final t = (1 - (i - pos).abs()).clamp(0.0, 1.0);
    return GestureDetector(
      key: _keys[i],
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onTap(i),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_padH, 0, _padH, 12),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Transform.scale(
            scale: 1 + _grow * t,
            alignment: Alignment.bottomCenter,
            child: Text(
              widget.labels[i],
              maxLines: 1,
              style: context.texts.titleMedium!.copyWith(
                fontSize: 15,
                height: 1.2,
                // 字重也不变:换字重会改宽度,短线就对不准了
                fontWeight: FontWeight.w700,
                color: Color.lerp(scheme.onSurfaceVariant, scheme.onSurface, t),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
