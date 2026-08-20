import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../editor_models.dart';
import 'rich_tag_controller.dart';
import '../../../core/util/haptics.dart';

/// 尾部输入框的定宽(有词条时)。约五个汉字宽,够看清正在打的词,
/// 又不至于自己独占一行把芯片流顶开。
const double _kInputWidth = 168;

/// 译文相对正文的字号差与行高倍数(chip 内两行的排版基准)。
/// 行高显式给死是**故意**的:译文是异步到货的,这一行的高度必须在译文来之前
/// 就能算出来,才好预留(见 [_TagChip] 里的占位)。
const double _kTransDrop = 4;
const double _kTransLine = 1.25;

/// 译文行占的高度(含与正文之间的 1px 间隙)。
double _transRowHeight(double fontSize) =>
    (fontSize - _kTransDrop) * _kTransLine + 1;

/// 芯片流视图(web 移动端 FullscreenEditor 芯片模式的形态):整体替换注音
/// 富文本,每个**顶层单元**一颗 chip —— 散标签是普通词条 chip(英文+译文双行,
/// 带权重角标/禁用删除线),折叠段是一颗 `#名字` chip(和普通标签同款外观,
/// 只多个折叠符号与主色边)。
///
/// 交互:点 chip 加选/取消(**可多选**)→ 未选中处浮现 ⊕ → 点 ⊕ 把所选整批
/// 搬过去,彼此相对顺序不变。折叠 chip 和散标签一视同仁,选中即整块移动
/// (moveUnits 保证记号跟随不卷入)。选中后的操作(权重/禁用/删除/解散)全在
/// 底部面板上 —— 这里没有光标,正文里那套「点标题解散」在本视图不存在。
///
/// 末尾跟一个输入框:芯片模式下这是唯一的打字入口,补全照常吸在键盘上。
/// 点空白处 = 清空选中并聚焦它(直接接着打字,不用瞄准那个小框)。
class ChipFlowView extends StatefulWidget {
  const ChipFlowView({
    super.key,
    required this.controller,
    required this.foldBodies,
    required this.selection,
    required this.onSelectionChanged,
    required this.onMove,
    required this.input,
    required this.inputFocus,
    required this.onInputChanged,
    required this.onInputSubmitted,
    required this.translating,
    this.showTrans = true,
    this.fontSize = 16,
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

  /// 尾部输入框(页面持有:补全管线要读它的文本)。
  final TextEditingController input;
  final FocusNode inputFocus;

  /// 每次输入:页面据此跑补全,并在遇到逗号时把前半截落成标签。
  final ValueChanged<String> onInputChanged;

  /// 回车/完成:整条落成标签。
  final ValueChanged<String> onInputSubmitted;

  /// 译文行开关(编辑器设置的注音开关):关=chip 收成单行。
  final bool showTrans;

  /// 这枚标签的译文是否还在路上(排队/在问)。离线补全模式恒 false ——
  /// 那边没人去问,挂着加载动画等于骗人。
  final bool Function(String name) translating;

  /// 正文字号(编辑器设置 14/16/18):chip 整体大小跟着走,和注音富文本同一档。
  final double fontSize;

  /// 异常权重阈值(编辑器设置)。
  final double abnormalThreshold;

  @override
  State<ChipFlowView> createState() => _ChipFlowViewState();
}

class _ChipFlowViewState extends State<ChipFlowView>
    with TickerProviderStateMixin {

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

  /// 译文加载态的脉动:整片 chip 共用一个 ticker,且只在**真有词在等**时才转
  /// (没人等还空转 = 白烧一整屏的帧)。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );
  bool _pulsing = false;

  @override
  void dispose() {
    _moveAnim.dispose();
    _pulse.dispose();
    super.dispose();
  }

  /// 起停脉动。**必须挪到帧后**:repeat/stop 会同步 notifyListeners,
  /// build 期间通知已经挂上的 AnimatedBuilder 会撞 markNeedsBuild 断言。
  void _syncPulse(bool on) {
    if (on == _pulsing) return;
    _pulsing = on;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pulsing) {
        _pulse.repeat(reverse: true);
      } else {
        _pulse.stop();
      }
    });
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
        bool pendingOf(TopUnit u) =>
            widget.showTrans &&
            !u.isFold &&
            u.tok!.trans == null &&
            widget.translating(u.tok!.name);
        _syncPulse(units.any(pendingOf));
        final t = Curves.easeOutCubic.transform(_moveAnim.value);
        return GestureDetector(
          // 点空白 = 取消选中 + 聚焦输入框。芯片之间的缝隙本来什么也不是,
          // 让它接管「我要接着打字」这个最高频的意图。
          behavior: HitTestBehavior.opaque,
          onTap: _tapBlank,
          child: SingleChildScrollView(
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
                        _slide(
                          i,
                          t,
                          _chipFor(text, units[i], i, sel, pendingOf(units[i])),
                        ),
                      _inputBox(units.isEmpty),
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
          ),
        );
      },
    );
  }

  void _tapBlank() {
    if (_sel.isNotEmpty) widget.onSelectionChanged({});
    widget.inputFocus.requestFocus();
  }

  /// 尾部输入框。Wrap 里的孩子拿不到「本行剩余宽度」,所以给定宽:空正文时
  /// 占满一行(那时它就是整个编辑区),有词条时 [_kInputWidth] 跟在最后一颗
  /// chip 后面,放不下自动换行。文本超出宽度由 TextField 自己横向滚。
  Widget _inputBox(bool empty) {
    final scheme = context.scheme;
    final fs = widget.fontSize;
    return SizedBox(
      width: empty ? double.infinity : _kInputWidth,
      child: TextField(
        controller: widget.input,
        focusNode: widget.inputFocus,
        onChanged: widget.onInputChanged,
        onSubmitted: (v) {
          widget.onInputSubmitted(v);
          widget.inputFocus.requestFocus(); // 落一枚接着打下一枚
        },
        textInputAction: TextInputAction.done,
        style: TextStyle(fontSize: fs, color: scheme.onSurface),
        cursorColor: scheme.primary,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 7),
          hintText: empty ? '输入标签,可输入中文自动翻译' : '继续添加…',
          hintStyle: TextStyle(fontSize: fs, color: scheme.outline),
        ),
      ),
    );
  }

  Widget _chipFor(
    String text,
    TopUnit u,
    int i,
    Set<int> sel,
    bool translating,
  ) {
    if (u.isFold) {
      return _FoldChip(
        key: _chipKeys[i],
        name: u.fold!.name,
        count: _memberCount(u.fold!),
        fontSize: widget.fontSize,
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
      showTrans: widget.showTrans,
      translating: translating,
      pulse: _pulse,
      fontSize: widget.fontSize,
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
    required this.fontSize,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final int count;
  final double fontSize;
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
          padding: EdgeInsets.symmetric(
            horizontal: fontSize * 0.7,
            vertical: 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '#',
                style: TextStyle(
                  fontSize: fontSize,
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
                    fontSize: fontSize,
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
                  size: fontSize - _kTransDrop,
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
    required this.showTrans,
    required this.translating,
    required this.pulse,
    required this.fontSize,
    required this.selected,
    required this.onTap,
    this.abnormal = false,
    this.sd = false,
  });

  final Tok tok;

  /// 译文行:开着就**恒占一行**(有没有译文都占)。
  final bool showTrans;

  /// 译文还在路上:那一行画一条脉动占位条,而不是空着。
  final bool translating;

  /// 加载态共用的脉动(整片 chip 一个 ticker,不是一颗一个)。
  final Animation<double> pulse;

  final double fontSize;
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
    if (tok.disabled) {
      // 禁用要一眼看得出来。原先只是「正常 chip + 灰字 + 一道细划线」,
      // 底和边框和旁边的普通 chip 一模一样,扫过去根本分不出来(实测反馈)。
      // 改成往下沉一档的底 + 淡到几乎没有的边:整颗 chip 从这一片里退出去。
      chipBg = scheme.surfaceContainerLowest;
      chipBorder = scheme.outlineVariant.withValues(alpha: .4);
    } else if (abnormal && !tok.disabled) {
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
          padding: EdgeInsets.symmetric(
            horizontal: fontSize * 0.7,
            vertical: 6,
          ),
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
                        fontSize: fontSize,
                        fontWeight: FontWeight.w600,
                        color: tok.disabled ? scheme.outline : scheme.onSurface,
                        decoration: tok.disabled
                            ? TextDecoration.lineThrough
                            : null,
                        decorationColor: scheme.outline,
                        decorationThickness: 2,
                      ),
                    ),
                  ),
                  if (weightColor != null) ...[
                    const SizedBox(width: 5),
                    Text(
                      '×${fmtMult(mult)}',
                      // 读数只报数,不跟着权重变红蓝 —— 高低看 chip 底色与边框
                      style: TextStyle(
                        fontSize: fontSize - _kTransDrop,
                        fontWeight: FontWeight.w700,
                        color: tok.disabled
                            ? scheme.outline
                            : scheme.onSurface,
                      ),
                    ),
                  ],
                ],
              ),
              // 译文行恒占位:译文是异步到货的,不预留高度的话每回一批就有
              // 一片 chip 先矮后长,整屏跟着重排 —— 那一下比没有译文难受得多。
              // 高度按字号算死(不靠内容撑),空着/加载中/有字三态严格等高。
              if (showTrans)
                SizedBox(
                  height: _transRowHeight(fontSize),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    // widthFactor 必须给。不给 = Align 撑满可用宽度,
                    // Column 跟着变满宽,整颗 chip 独占一整行(真机反馈修复)。
                    widthFactor: 1,
                    child: tok.trans != null
                        ? Text(
                            tok.trans!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: fontSize - _kTransDrop,
                              height: _kTransLine,
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        : translating
                        ? _TransPulse(pulse: pulse, fontSize: fontSize)
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 译文加载中的占位条。那一行本来就留着(见 [_transRowHeight]),与其空着,
/// 不如让它自己说明「在路上」—— 否则用户分不清是没译文还是还没到。
/// 只画一条脉动的小色块:文字版(「翻译中…」)比多数译文还长,一到货整行宽度
/// 就跳一下,反倒把预留高度省下的那点安定感又赔进去。
class _TransPulse extends StatelessWidget {
  const _TransPulse({required this.pulse, required this.fontSize});

  final Animation<double> pulse;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = context.scheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, _) => Container(
        width: fontSize * 2.4,
        height: (fontSize - _kTransDrop) * 0.66,
        decoration: BoxDecoration(
          color: c.withValues(alpha: .10 + .16 * pulse.value),
          borderRadius: BorderRadius.circular(3),
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
