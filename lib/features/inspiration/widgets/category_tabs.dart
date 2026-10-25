import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/theme/app_theme.dart';

/// 灵感页顶栏的分类页签:一条连续的横滚标签,选中项放大加深、下面一道主色短线。
/// 正文左右滑时 [swipe] 给出往相邻页签的进度(正 = 往后一个),短线和字跟手过渡,
/// 标签条跟着滚,让当前项保持在中间;点页签时同样滑过去。行末固定一颗「类别管理」。
class CategoryTabs extends StatefulWidget {
  const CategoryTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onTap,
    this.swipe,
    this.onManage,
    this.leftPad = 14,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onTap;

  /// 正文滑动进度(-1 ~ 1);null = 不跟手。
  final ValueListenable<double>? swipe;

  /// null = 不出行末的「类别管理」。
  final VoidCallback? onManage;
  final double leftPad;

  @override
  State<CategoryTabs> createState() => _CategoryTabsState();
}

class _CategoryTabsState extends State<CategoryTabs>
    with SingleTickerProviderStateMixin {
  static const _padH = 11.0;

  /// 选中项放大的比例。字号不变、只做缩放,页签宽度就是固定的,短线好对位。
  static const _grow = .2;

  final _scroll = ScrollController();
  final _stripKey = GlobalKey();
  final _keys = <GlobalKey>[];

  /// 各页签中心在标签条里的横坐标(量出来的);没量到之前不画短线。
  List<double> _centers = const [];

  /// 点页签 / 滑完以后的位置过渡。
  late final _anim = AnimationController(vsync: this, duration: Motion.medium)
    ..value = 1;
  late double _from = widget.index.toDouble();
  late double _to = widget.index.toDouble();

  /// 上一帧画出来的位置:换页签时从这儿滑过去,滑动刚换完页时就不会往回跳。
  late double _lastPos = widget.index.toDouble();

  double get _swipe => widget.swipe?.value ?? 0;

  double get _pos {
    final s = _swipe;
    if (s != 0) return widget.index + s;
    return _from +
        (_to - _from) * Motion.standard.transform(_anim.value.clamp(0, 1));
  }

  @override
  void initState() {
    super.initState();
    widget.swipe?.addListener(_onSwipe);
    _anim.addListener(_follow);
    _measureLater();
  }

  @override
  void didUpdateWidget(covariant CategoryTabs old) {
    super.didUpdateWidget(old);
    if (old.swipe != widget.swipe) {
      old.swipe?.removeListener(_onSwipe);
      widget.swipe?.addListener(_onSwipe);
    }
    if (old.labels.join('\n') != widget.labels.join('\n')) _measureLater();
    if (old.index != widget.index) _glide(_lastPos);
  }

  void _glide(double from) {
    _from = from;
    _to = widget.index.toDouble();
    _anim.forward(from: 0);
  }

  void _onSwipe() {
    if (_swipe == 0) {
      // 滑动结束:停在当前画出来的地方;换了页的话下一帧 index 才更新,
      // 到时候再从这儿滑到位(没换页就是滑回原位)
      final stop = _lastPos;
      _from = _to = stop;
      _anim.value = 1;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _glide(stop);
      });
    }
    _follow();
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
    widget.swipe?.removeListener(_onSwipe);
    _anim.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    while (_keys.length < widget.labels.length) {
      _keys.add(GlobalKey());
    }
    final pos = _lastPos = _pos;
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
