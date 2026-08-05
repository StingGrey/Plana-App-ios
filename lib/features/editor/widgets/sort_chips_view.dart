import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../editor_models.dart';
import 'rich_tag_controller.dart';
import '../../../core/util/haptics.dart';

/// 多选模式的 chip 流视图(web DesktopChipEditor 形态):替换文本渲染,
/// 每个**顶层单元**一颗 chip —— 散标签是普通词条 chip(英文+译文双行,带权重
/// 角标/禁用删除线),折叠段是一颗 `#名字` chip(和普通标签同款外观,只多个
/// 折叠符号与主色边)。
///
/// 交互:点 chip 加选/取消(**可多选**)→ 未选中处浮现 ⊕ → 点 ⊕ 把所选整批
/// 搬过去,彼此相对顺序不变。折叠 chip 和散标签一视同仁,选中即整块移动
/// (moveUnits 保证记号跟随不卷入)。批量禁用/删除在底部操作条上。
/// 折叠的**解散**在正文里点标题做,这里不重复入口。
class SortChipsView extends StatefulWidget {
  const SortChipsView({
    super.key,
    required this.controller,
    required this.foldBodies,
    required this.selection,
    required this.onSelectionChanged,
    required this.onMove,
    this.abnormalThreshold = 10,
  });

  final RichTagController controller;

  /// 折叠表(名字 -> 折叠体):识别占位符 + 数成员。
  final Map<String, String> foldBodies;

  /// 已选顶层单元下标。**状态提在页面上** —— 底部批量操作条要读它,
  /// 而且改完文本后要由页面决定清不清选中。
  final Set<int> selection;
  final ValueChanged<Set<int>> onSelectionChanged;

  /// 把已选单元整批移到间隙 [to](原序下标)。
  final void Function(int to) onMove;

  /// 异常权重阈值(编辑器设置)。
  final double abnormalThreshold;

  @override
  State<SortChipsView> createState() => _SortChipsViewState();
}

class _SortChipsViewState extends State<SortChipsView>
    with SingleTickerProviderStateMixin {

  final GlobalKey _stackKey = GlobalKey();
  final List<GlobalKey> _chipKeys = [];
  List<(int, Offset)> _anchors = const []; // (gap, 加号中心) 内容坐标

  // FLIP 插入动画:每颗 chip 从旧槽位滑到新槽位(不闪跳)。
  late final AnimationController _moveAnim =
      AnimationController(vsync: this, duration: Motion.medium)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed &&
              mounted &&
              _startOffsets.isNotEmpty) {
            setState(() => _startOffsets = const {});
          }
        });
  Map<int, Offset> _startOffsets = const {}; // 单元下标 → 起始位移(内容坐标)

  @override
  void dispose() {
    _moveAnim.dispose();
    super.dispose();
  }

  Set<int> get _sel => widget.selection;

  void _tapChip(int i) {
    Haptics.selection();
    // 在途滑动先归位并清位移,保证下次插入量到干净布局
    if (_startOffsets.isNotEmpty) {
      _moveAnim.value = 1;
      _startOffsets = const {};
    }
    final next = {...widget.selection};
    if (!next.remove(i)) next.add(i);
    widget.onSelectionChanged(next);
  }

  /// 量各 chip 相对 Stack 的矩形(未布局返回 null)。
  List<Rect>? _measureRects(int count) {
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null) return null;
    final rects = <Rect>[];
    for (var i = 0; i < count; i++) {
      final b = _chipKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (b == null || !b.hasSize) return null;
      final tl = b.localToGlobal(Offset.zero, ancestor: stackBox);
      rects.add(tl & b.size);
    }
    return rects;
  }

  void _insert(int gap) {
    final sel = _sel.toList()..sort();
    if (sel.isEmpty) return;
    Haptics.medium();
    final n = topLevelUnits(widget.controller.text, widget.foldBodies).length;
    // 收前先把在途动画归位(value=1 → 现有 Transform 位移为 0,量到干净布局)
    _moveAnim.value = 1;
    final oldRects = _measureRects(n);
    widget.onMove(gap); // 改文本 + 清选中 → 触发重建(chip 跳到新槽)
    if (oldRects == null) return; // 量不到就不动画,内容已更新

    // 新下标 j 处的 chip 来自旧下标 order[j] —— 与 moveUnits 同一套换算
    var at = 0;
    for (var i = 0; i < gap && i < n; i++) {
      if (!_selWas(sel, i)) at++;
    }
    final order = [
      for (var i = 0; i < n; i++)
        if (!_selWas(sel, i)) i,
    ]..insertAll(at.clamp(0, n - sel.length), sel);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final newRects = _measureRects(n);
      if (newRects == null) return;
      final starts = <int, Offset>{};
      for (var j = 0; j < n; j++) {
        final delta = oldRects[order[j]].topLeft - newRects[j].topLeft;
        if (delta.distance > 0.5) starts[j] = delta;
      }
      if (starts.isEmpty) return;
      setState(() => _startOffsets = starts);
      _moveAnim.forward(from: 0);
    });
  }

  static bool _selWas(List<int> sorted, int i) => sorted.contains(i);

  /// 布局后按 chip 实际位置计算间隙加号锚点(浮层,不占 Wrap 位——
  /// 加号出现/消失时 chip 一动不动)。结果收敛才 setState,防循环。
  void _scheduleAnchors(int count) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sel = _sel;
      if (sel.isEmpty || count == 0 || sel.length >= count) {
        if (_anchors.isNotEmpty) setState(() => _anchors = const []);
        return;
      }
      final stackBox =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      if (stackBox == null) return;
      final rects = <Rect>[];
      for (final k in _chipKeys.take(count)) {
        final b = k.currentContext?.findRenderObject() as RenderBox?;
        if (b == null || !b.hasSize) return;
        final tl = b.localToGlobal(Offset.zero, ancestor: stackBox);
        rects.add(tl & b.size);
      }
      final next = <(int, Offset)>[];
      for (var g = 0; g <= rects.length; g++) {
        // 落点等于原位就没意义:间隙两侧都被选中(搬过去还是那儿),或者
        // 紧贴选中块的两端。判据 —— 间隙左右各自是不是选中项。
        final leftSel = g > 0 && sel.contains(g - 1);
        final rightSel = g < rects.length && sel.contains(g);
        if (leftSel && rightSel) continue;
        if (_noOpGap(sel, g, rects.length)) continue;
        final Offset pos;
        if (g == rects.length) {
          final r = rects.last;
          pos = Offset(r.right + 4, r.center.dy);
        } else {
          final r = rects[g];
          pos = Offset(r.left - 4, r.center.dy);
        }
        next.add((g, Offset(pos.dx.clamp(12.0, double.maxFinite), pos.dy)));
      }
      if (!_sameAnchors(next)) setState(() => _anchors = next);
    });
  }

  /// 搬到间隙 [g] 之后顺序完全没变 → 这个 ⊕ 是空操作,别画出来。
  /// 直接按 moveUnits 的换算跑一遍新序,与原序比对,省得逐种情况讨论。
  bool _noOpGap(Set<int> sel, int g, int n) {
    var at = 0;
    for (var i = 0; i < g && i < n; i++) {
      if (!sel.contains(i)) at++;
    }
    final sorted = sel.toList()..sort();
    final next = [
      for (var i = 0; i < n; i++)
        if (!sel.contains(i)) i,
    ]..insertAll(at.clamp(0, n - sel.length), sorted);
    for (var i = 0; i < n; i++) {
      if (next[i] != i) return false;
    }
    return true;
  }

  bool _sameAnchors(List<(int, Offset)> next) {
    if (next.length != _anchors.length) return false;
    for (var i = 0; i < next.length; i++) {
      if (next[i] != _anchors[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.controller, _moveAnim]),
      builder: (context, _) {
        final text = widget.controller.text;
        final units = topLevelUnits(text, widget.foldBodies);
        final sel = {
          for (final i in _sel)
            if (i < units.length) i,
        };
        while (_chipKeys.length < units.length) {
          _chipKeys.add(GlobalKey());
        }
        _scheduleAnchors(units.length);
        final t = Curves.easeOutCubic.transform(_moveAnim.value);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          child: Stack(
            key: _stackKey,
            clipBehavior: Clip.none,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 0; i < units.length; i++)
                      _slide(i, t, _chipFor(text, units[i], i, sel)),
                  ],
                ),
              ),
              if (sel.isNotEmpty)
                for (final (g, pos) in _anchors)
                  Positioned(
                    left: pos.dx - 15,
                    top: pos.dy - 15,
                    child: _PlusDot(onTap: () => _insert(g)),
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _chipFor(String text, TopUnit u, int i, Set<int> sel) {
    if (u.isFold) {
      return _FoldChip(
        key: _chipKeys[i],
        name: u.fold!.name,
        count: _memberCount(u.fold!),
        selected: sel.contains(i),
        onTap: () => _tapChip(i),
      );
    }
    final tok = u.tok!;
    return _TagChip(
      key: _chipKeys[i],
      tok: tok,
      abnormal:
          abnormalWeightOf(text, tok, threshold: widget.abnormalThreshold) !=
          null,
      sd: isSdWeightSeg(text.substring(tok.segStart, tok.segEnd)),
      selected: sel.contains(i),
      onTap: () => _tapChip(i),
    );
  }

  int _memberCount(FoldRef f) =>
      parseToks(widget.foldBodies[f.name] ?? '').length;

  /// FLIP:动画中把第 [i] 颗 chip 从起始位移滑回 0(paint-time,不改布局)。
  Widget _slide(int i, double t, Widget child) {
    final start = _startOffsets[i];
    if (start == null || t >= 1) return child;
    return Transform.translate(offset: start * (1 - t), child: child);
  }
}

/// 折叠 chip:和普通标签同款外观(单行,主色系),前缀 `#` 折叠符号 + 成员数。
/// 点它选中/移动,和散标签一视同仁;解散在正文点标题做。
class _FoldChip extends StatelessWidget {
  const _FoldChip({
    super.key,
    required this.name,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: selected
          ? scheme.primaryContainer
          : scheme.primary.withValues(alpha: .10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(
          color: selected
              ? scheme.primary
              : scheme.primary.withValues(alpha: .45),
          width: selected ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '#',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: mono(
                  context,
                  size: 11,
                  weight: FontWeight.w700,
                ).copyWith(color: scheme.primary.withValues(alpha: .8)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    super.key,
    required this.tok,
    required this.selected,
    required this.onTap,
    this.abnormal = false,
    this.sd = false,
  });

  final Tok tok;
  final bool selected;
  final VoidCallback onTap;

  /// 异常权重(词中段疑似丢逗号的 `N::`):红底红框警示,盖过权重色。
  final bool abnormal;

  /// SD 权重语法 `(tag:1.2)`:tertiary 底提示可转换。
  final bool sd;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pal = context.editor;
    final mult = tok.effMult;
    final weightColor = mult > 1.0001
        ? pal.weightUp
        : mult < 0.9999
        ? pal.weightDown
        : null;
    // 权重底色/边框(web getWeightStyle 同款):越偏离 1 越深,禁用不铺色;
    // 异常权重红底红框优先(web abnormalWeight 同款)。
    var chipBg = scheme.surfaceContainerHigh;
    var chipBorder = scheme.outlineVariant;
    if (abnormal && !tok.disabled) {
      chipBg = Color.alphaBlend(
        scheme.error.withValues(alpha: .14),
        scheme.surfaceContainerHigh,
      );
      chipBorder = scheme.error.withValues(alpha: .55);
    } else if (sd && !tok.disabled) {
      chipBg = Color.alphaBlend(
        scheme.tertiary.withValues(alpha: .14),
        scheme.surfaceContainerHigh,
      );
      chipBorder = scheme.tertiary.withValues(alpha: .55);
    } else if (weightColor != null && !tok.disabled) {
      // 与正文色带同源:EditorPalette.weightWash 统一色相与强度曲线
      final up = mult > 1;
      final i = up
          ? ((mult - 1) / 1.5).clamp(0.0, 1.0)
          : ((1 - mult) / 0.7).clamp(0.0, 1.0);
      chipBg = Color.alphaBlend(
        pal.weightWash(mult)!,
        scheme.surfaceContainerHigh,
      );
      chipBorder = (up ? pal.weightUpBorder : pal.weightDownBorder).withValues(
        alpha: .45 + i * .35,
      );
    }
    return Material(
      color: selected ? scheme.primaryContainer : chipBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(
          color: selected ? scheme.primary : chipBorder,
          width: selected ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      tok.name,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: tok.disabled ? scheme.outline : scheme.onSurface,
                        decoration: tok.disabled
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                  if (weightColor != null) ...[
                    const SizedBox(width: 5),
                    Text(
                      '×${fmtMult(mult)}',
                      // 读数只报数,不跟着权重变红蓝 —— 高低看 chip 底色与边框
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: tok.disabled
                            ? scheme.outline
                            : scheme.onSurface,
                      ),
                    ),
                  ],
                ],
              ),
              if (tok.trans != null) ...[
                const SizedBox(height: 1),
                Text(
                  tok.trans!,
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// chip 间的插入加号(选中词条后浮现)。
class _PlusDot extends StatelessWidget {
  const _PlusDot({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.primaryContainer,
      shape: CircleBorder(
        side: BorderSide(color: scheme.primary.withValues(alpha: .5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(Icons.add, size: 18, color: scheme.primary),
        ),
      ),
    );
  }
}
