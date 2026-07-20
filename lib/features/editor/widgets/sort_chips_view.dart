import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../editor_models.dart';
import 'rich_tag_controller.dart';

/// 排序模式的 chip 流视图(web DesktopChipEditor 形态):替换文本渲染,
/// 每枚词条一颗真 chip(英文+译文双行,带权重角标/禁用删除线)。
/// 交互:点 chip 选中 → 其余 chip 间浮现 ⊕ → 点 ⊕ 插入;
/// 点别的 chip 改选,点自身取消。文本经 onReorder 槽位法写回。
class SortChipsView extends StatefulWidget {
  const SortChipsView({
    super.key,
    required this.controller,
    required this.onReorder,
    this.abnormalThreshold = 10,
  });

  final RichTagController controller;

  /// 把第 from 枚移到 to(移除后下标)。
  final void Function(int from, int to) onReorder;

  /// 异常权重阈值(编辑器设置)。
  final double abnormalThreshold;

  @override
  State<SortChipsView> createState() => _SortChipsViewState();
}

class _SortChipsViewState extends State<SortChipsView>
    with SingleTickerProviderStateMixin {
  int? _sel; // 选中待移动的词条下标

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
  Map<int, Offset> _startOffsets = const {}; // 新下标 → 起始位移(内容坐标)

  @override
  void dispose() {
    _moveAnim.dispose();
    super.dispose();
  }

  void _tapChip(int i) {
    HapticFeedback.selectionClick();
    // 在途滑动先归位并清位移,保证下次插入量到干净布局
    if (_startOffsets.isNotEmpty) {
      _moveAnim.value = 1;
      _startOffsets = const {};
    }
    setState(() => _sel = _sel == i ? null : i);
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
    final sel = _sel;
    if (sel == null) return;
    final to = gap > sel ? gap - 1 : gap;
    if (to == sel) {
      setState(() => _sel = null);
      return;
    }
    HapticFeedback.mediumImpact();
    final n = parseToks(widget.controller.text).length;
    // 收前先把在途动画归位(value=1 → 现有 Transform 位移为 0,量到干净布局)
    _moveAnim.value = 1;
    final oldRects = _measureRects(n);
    setState(() => _sel = null);
    widget.onReorder(sel, to); // 改文本 → 触发重建(chip 跳到新槽)
    if (oldRects == null) return; // 量不到就不动画,内容已更新

    // 新下标 j 处的 chip 来自旧下标 order[j]
    final order = [for (var i = 0; i < n; i++) i];
    order.insert(to, order.removeAt(sel));

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

  /// 布局后按 chip 实际位置计算间隙加号锚点(浮层,不占 Wrap 位——
  /// 加号出现/消失时 chip 一动不动)。结果收敛才 setState,防循环。
  void _scheduleAnchors(int count) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sel = _sel;
      if (sel == null || count == 0) {
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
        if (g == sel || g == sel + 1) continue;
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
        final toks = parseToks(widget.controller.text);
        final sel = (_sel != null && _sel! < toks.length) ? _sel : null;
        while (_chipKeys.length < toks.length) {
          _chipKeys.add(GlobalKey());
        }
        _scheduleAnchors(toks.length);
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
                    for (var i = 0; i < toks.length; i++)
                      _slide(
                        i,
                        t,
                        _TagChip(
                          key: _chipKeys[i],
                          tok: toks[i],
                          abnormal:
                              abnormalWeightOf(
                                widget.controller.text,
                                toks[i],
                                threshold: widget.abnormalThreshold,
                              ) !=
                              null,
                          sd: isSdWeightSeg(
                            widget.controller.text.substring(
                              toks[i].segStart,
                              toks[i].segEnd,
                            ),
                          ),
                          selected: i == sel,
                          onTap: () => _tapChip(i),
                        ),
                      ),
                  ],
                ),
              ),
              if (sel != null)
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

  /// FLIP:动画中把第 [i] 颗 chip 从起始位移滑回 0(paint-time,不改布局)。
  Widget _slide(int i, double t, Widget child) {
    final start = _startOffsets[i];
    if (start == null || t >= 1) return child;
    return Transform.translate(offset: start * (1 - t), child: child);
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
      chipBorder = (up ? pal.weightUpBorder : pal.weightDownBorder)
          .withValues(alpha: .45 + i * .35);
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
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: weightColor,
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
