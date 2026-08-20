import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../data/suggestions.dart' show translationOf;
import '../editor_models.dart';
import '../../../core/util/haptics.dart';

/// 词条栏 / 权重面板 —— 光标右邻是本标签正文时吸在键盘上方。
/// 头部(名字·热度·翻译·复制·关闭)+ 权重(括号快捷键 · 数值加减,长按持续)
/// + 清除/关联/禁用/删除 + 关联标签(点「关联」才展开)。改动都由页面改文本落地。
class TagPanel extends StatefulWidget {
  const TagPanel({
    super.key,
    required this.tok,
    required this.count,
    required this.related,
    this.relatedLoading = false,
    this.weightStep = 0.1,
    this.compact = false,
    this.warning,
    this.sdConvert,
    this.onSelectGroup,
    required this.onWrap,
    required this.onSetMult,
    required this.onClear,
    required this.onToggleDisabled,
    required this.onDelete,
    required this.onAddRelated,
    required this.onClose,
    this.onRename,
  });

  final Tok tok;
  final int? count;
  final List<String> related;

  /// 行内改名(芯片模式专有:那边没有光标,改字只能从这里进)。
  /// null = 文本模式,点标题不进编辑态——直接点正文里那个词就行。
  final void Function(String name)? onRename;

  /// 异常权重警示:词中段疑似丢逗号的数字串(如 '10'),null=正常。
  final String? warning;

  /// 当前词条是 SD 权重语法时的转换回调(web convertSDToNAI);null=非 SD。
  final VoidCallback? sdConvert;

  /// 词条处于跨词条权重组时的「选中整组」回调(把选区扩到整组进批量
  /// 面板调组权重);null=不在组内。
  final VoidCallback? onSelectGroup;

  /// 数值加减每步的调整量(编辑器设置:0.05 / 0.1)。
  final double weightStep;

  /// 一行精简版(编辑器设置「精简词条栏」)。见 [_TagPanelState._compactRow]。
  final bool compact;

  /// 关联标签正在异步拉取(按钮不置灰,左侧显示转圈)。
  final bool relatedLoading;

  /// 括号快捷键:套一层 {}(up=true)或 [](up=false),不动数值
  final void Function(bool up) onWrap;

  /// 数值加减:改内层 `N::tag::` 倍率
  final void Function(double mult) onSetMult;

  /// 清除权重:去括号 + 数值
  final VoidCallback onClear;
  final VoidCallback onToggleDisabled;
  final VoidCallback onDelete;
  final void Function(String tag) onAddRelated;

  /// 关闭词条栏
  final VoidCallback onClose;

  @override
  State<TagPanel> createState() => _TagPanelState();
}

/// 精简词条栏的控件尺寸。抽成常量是因为 [_TagPanelState._compactRow] 要靠
/// 它们算「还放不放得下名字」—— 硬编码两份迟早对不上。
///
/// 比第一版粗了一圈(34/32/34 → 42/40/38):省掉那格 ×N 读数腾出来的 50 宽
/// 分给了按钮。这一栏就是拿来按的,第一版那种 32 的圆钮在拇指下面不好使。
///
/// 也没有粗到顶格 —— 再大一圈的话 393 那类常见宽度上就留不下名字了,
/// 而「你在改哪一枚」比「按钮再宽两像素」值钱。
const double _kWrapW = 42; // [ ] / { }
const double _kWrapH = 40;
const double _kStepW = 40; // ⊖ / ⊕
const double _kTailW = 38; // ⌫ / 🗑 / ⚠ / ⇄

class _TagPanelState extends State<TagPanel> {
  bool _relatedOpen = false; // 关联标签是否展开
  bool _renaming = false; // 标题处于行内改名态
  final TextEditingController _nameCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  @override
  void didUpdateWidget(TagPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切到另一枚标签时收起关联与改名(同枚改权重则保持)
    if (oldWidget.tok.name != widget.tok.name) {
      _relatedOpen = false;
      _renaming = false;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _startRename() {
    final name = widget.tok.name;
    _nameCtrl.value = TextEditingValue(
      text: name,
      // 全选:改名多半是整枚换掉,不是补字
      selection: TextSelection(baseOffset: 0, extentOffset: name.length),
    );
    setState(() => _renaming = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  void _commitRename() {
    final v = _nameCtrl.text.trim();
    setState(() => _renaming = false);
    _nameFocus.unfocus();
    if (v.isEmpty || v == widget.tok.name) return;
    widget.onRename?.call(v);
  }

  void _cancelRename() {
    setState(() => _renaming = false);
    _nameFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pal = context.editor;
    final tok = widget.tok;
    final on = !tok.disabled;

    // 读数/名字色以**自身**权重为准(组权重单独一行展示,web 同款语义):
    // +/− 与清除操作的对象都是自身权重,读数一致才不跳变。
    final Color wc = tok.disabled
        ? scheme.onSurfaceVariant
        : tok.ownMult > 1.0001
        ? pal.weightUp
        : tok.ownMult < 0.9999
        ? pal.weightDown
        : scheme.onSurface;

    final hasRelated = widget.related.isNotEmpty;

    if (widget.compact) {
      return Material(
        color: scheme.surfaceContainer,
        child: Padding(
          // 上下各 8:按钮 40 高,一行落在 56 —— 完整版是 175
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
          child: _compactRow(context, wc),
        ),
      );
    }

    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              tok: tok,
              count: widget.count,
              wc: wc,
              onClose: widget.onClose,
              renaming: _renaming,
              nameCtrl: _nameCtrl,
              nameFocus: _nameFocus,
              onStartRename: widget.onRename == null ? null : _startRename,
              onCommitRename: _commitRename,
              onCancelRename: _cancelRename,
            ),
            // 跨词条权重组信息:自身读数之外单独陈述组权重与合计,
            // 「选中整组」一键进批量面板调组权重。
            if ((tok.groupMult - 1).abs() > 0.0001)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  children: [
                    Icon(
                      Icons.layers_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '处于权重组 ×${fmtMult(tok.groupMult)} · '
                        '合计 ×${fmtMult(tok.effMult)}',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (widget.onSelectGroup != null)
                      Material(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(9),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: widget.onSelectGroup,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            child: Text(
                              '选中整组',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (widget.warning != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 15,
                      color: scheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '「${widget.warning}」可能被误识别为权重,疑似丢了逗号',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.sdConvert != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Material(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.sdConvert,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 9,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.autorenew,
                            size: 16,
                            color: scheme.onTertiaryContainer,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              'SD 权重语法 · 点击转换为 NAI 格式',
                              style: context.texts.labelMedium!.copyWith(
                                color: scheme.onTertiaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: scheme.onTertiaryContainer,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            // 权重:括号快捷键(左)· 数值加减(右,支持长按持续步进,读数居中)
            Row(
              children: [
                Text(
                  '权重',
                  style: context.texts.bodyMedium!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                _weightBtn(
                  context,
                  '[ ]',
                  pal.weightDown,
                  scheme.onError,
                  enabled: on,
                  onTap: () => widget.onWrap(false),
                ),
                const SizedBox(width: 6),
                _weightBtn(
                  context,
                  '{ }',
                  pal.weightUp,
                  scheme.onError,
                  enabled: on,
                  onTap: () => widget.onWrap(true),
                ),
                const Spacer(),
                _RepeatBtn(
                  icon: Icons.remove,
                  enabled: on,
                  step: () => widget.onSetMult(tok.numMult - widget.weightStep),
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    '×${fmtMult(tok.ownMult)}',
                    textAlign: TextAlign.center,
                    // 读数只报数,不跟着权重变红蓝 —— 高低看名字色与正文色带
                    style: mono(
                      context,
                      size: 16,
                      color: tok.disabled
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface,
                    ),
                  ),
                ),
                _RepeatBtn(
                  icon: Icons.add,
                  enabled: on,
                  step: () => widget.onSetMult(tok.numMult + widget.weightStep),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 操作:清除权重 · 关联(点开展开)· 禁用 · 删除
            Row(
              children: [
                Expanded(
                  child: _action(
                    context,
                    '清除权重',
                    enabled:
                        on &&
                        (tok.braceLevel != 0 ||
                            (tok.numMult - 1.0).abs() >= 0.005),
                    onTap: widget.onClear,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    context,
                    '关联',
                    icon: widget.relatedLoading
                        ? null
                        : (_relatedOpen
                              ? Icons.expand_less
                              : Icons.expand_more),
                    // 加载中:左侧转圈,按钮不置灰(点击暂无动作)
                    leading: widget.relatedLoading
                        ? SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        : null,
                    enabled: widget.relatedLoading || hasRelated,
                    selected: _relatedOpen,
                    onTap: widget.relatedLoading
                        ? () {}
                        : () => setState(() => _relatedOpen = !_relatedOpen),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    context,
                    tok.disabled ? '启用' : '禁用',
                    icon: tok.disabled
                        ? Icons.visibility
                        : Icons.visibility_off,
                    enabled: true,
                    onTap: widget.onToggleDisabled,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    context,
                    '删除',
                    icon: Icons.delete_outline,
                    danger: true,
                    enabled: true,
                    onTap: widget.onDelete,
                  ),
                ),
              ],
            ),
            // 关联标签:点「关联」展开一行横向滚动(定高,再多也不溢出;
            // Wrap 多行版在词多时撑破 dock 区,真机反馈弃用)
            AnimatedSize(
              duration: Motion.fast,
              curve: Motion.emphasized,
              alignment: Alignment.topCenter,
              child: (_relatedOpen && hasRelated)
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SizedBox(
                        height: 54,
                        width: double.infinity,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.related.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, i) => _relChip(
                            context,
                            widget.related[i],
                            () => widget.onAddRelated(widget.related[i]),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行精简版。**只留权重的全部功能 + 删除**。
  ///
  ///     [⚠] blue eyes ×1.2 [⇄]     [ ] ⊖   ⊕ { }     ⌫  🗑
  ///
  /// 取舍:
  ///  · 名字之外的头部信息(热度 / 译文 / 维基 / 复制 / 改名)全收走 ——
  ///    译文在正文的注音层里就有,热度只在挑词时有用,而这一栏是**调权重**的;
  ///  · 禁用、关联也收走:前者不是权重,后者要展开第二行,和「一行」冲突;
  ///  · 括号、数值加减、清除权重三样一个不少 —— 用户要的是「权重相关的所有
  ///    功能」,把清除塞进读数的长按里省宽度是省错了地方,那等于砍功能;
  ///  · **没有独立的 ×N 读数格**:×1 占着 50 宽却什么也没说,而真有权重时
  ///    直接缀在名字后面就够了(那是同一件事的两半:哪一枚、多重)。省下的
  ///    宽度全给了按钮 —— 这一栏是拿来按的,不是拿来读的;
  ///  · 关闭也去了:光标挪开(文本模式)、再点一下那枚 chip 或点空白
  ///    (芯片模式)都会收走它,一枚只为「原地藏起来」的 ✕ 不值 40 宽。
  ///
  /// 四颗权重键排成 `[ ] ⊖ ⊕ { }` —— 左半降权右半加权,中间留一道缝当轴。
  /// 括号是彩的、数值是中性圆钮,两种机制一眼分得开(和完整版同一套配色)。
  ///
  /// 宽度不够时**分两级让**,而不是让 Row 溢出(那会画出黄黑条并且真的点不到):
  ///  ① 先让名字 —— 挤成一个「…」既没信息又难看,而这枚标签就在正上方的
  ///    正文里高亮着;
  ///  ② 名字让完还是不够(分屏 / 超窄机)就整排改成横向可滚 —— 功能一个
  ///    不少,只是要划一下。
  Widget _compactRow(BuildContext context, Color wc) {
    final scheme = context.scheme;
    final pal = context.editor;
    final tok = widget.tok;
    final on = !tok.disabled;
    final canClear =
        on && (tok.braceLevel != 0 || (tok.numMult - 1.0).abs() >= 0.005);
    final inGroup = (tok.groupMult - 1).abs() > 0.0001;
    final weighted = (tok.ownMult - 1).abs() > 0.005;

    // 固定宽的那几段。**改控件尺寸要同步改这里** —— 这几个数是让位判断的
    // 依据,对不上就会在该滚的时候不滚(溢出)或者不该滚的时候滚。
    const clusterW = (_kWrapW + 2 + _kStepW) * 2 + 6; // [ ]⊖ ⊕{ }
    const tailW = _kTailW * 2 + 2; // ⌫ 🗑
    const gaps = 8.0 + 10; // 名字→簇、簇→尾
    final extra =
        (widget.warning != null ? _kTailW + 6 : 0) +
        (widget.sdConvert != null ? _kTailW + 8 : 0);
    final fixed = clusterW + tailW + gaps + extra;

    // 权重后缀实际有多宽 —— **量出来,不要估**。第一版按「四个字符 × 半宽」
    // 估成 30,真实是 51(× 在等宽字体里不窄,而且系统字号还会放大它),
    // 于是「放得下」判成了放不下的宽度,当场溢出。
    final suffixStyle = mono(context, size: 12.5);
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String t) {
      final tp = TextPainter(
        text: TextSpan(text: t, style: suffixStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      return tp.width;
    }

    final suffixW =
        (weighted ? measure('×${fmtMult(tok.ownMult)}') + 5 : 0.0) +
        (inGroup ? 17.0 : 0.0);

    /// 名字 + 权重后缀。**合成一段**:哪一枚、多重,本来就是同一件事的两半,
    /// 拆成两个控件反而要多占一格。×1 时后缀整个不出现 —— 没有权重的时候
    /// 「×1」这三个字符什么也没说。
    Widget label({bool nameless = false}) {
      final style = context.texts.bodyMedium!.copyWith(
        color: wc,
        fontWeight: FontWeight.w700,
        decoration: tok.disabled ? TextDecoration.lineThrough : null,
      );
      return GestureDetector(
        // 在权重组里时长按报组信息:组权重与合计在精简版里没地方常驻,
        // 而不说的话后缀(自身 ×1)会和正文里明显被加权的样子对不上,
        // 那是这一栏在骗人。旁边那枚图层图标是「这里还有话」的记号。
        onLongPress: inGroup
            ? () {
                Haptics.selection();
                hintSnack(
                  context,
                  '处于权重组 ×${fmtMult(tok.groupMult)} · '
                  '合计 ×${fmtMult(tok.effMult)}',
                  icon: Icons.layers_outlined,
                );
              }
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!nameless)
              Flexible(
                child: Text(
                  tok.name.isEmpty ? '标签' : tok.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            if (weighted) ...[
              if (!nameless) const SizedBox(width: 5),
              Text(
                // 跟着名字一起着色(完整版那格读数是中性的,那是因为它旁边就是
                // 两颗彩色按钮;这里它是名字的一部分,配色不一致反而像坏了)
                '×${fmtMult(tok.ownMult)}',
                style: suffixStyle.copyWith(color: wc),
              ),
            ],
            if (inGroup) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.layers_outlined,
                size: 13,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      );
    }

    // 名字之后那一整串(顺序固定,两种排法共用)
    List<Widget> controls() => [
      if (widget.sdConvert != null) ...[
        _denseIcon(
          context,
          Icons.autorenew,
          color: scheme.tertiary,
          tooltip: 'SD 权重语法 · 转成 NAI',
          onTap: widget.sdConvert!,
        ),
        const SizedBox(width: 8),
      ],
      const SizedBox(width: 8),
      _weightBtn(
        context,
        '[ ]',
        pal.weightDown,
        scheme.onError,
        enabled: on,
        onTap: () => widget.onWrap(false),
        width: _kWrapW,
        height: _kWrapH,
      ),
      const SizedBox(width: 2),
      _RepeatBtn(
        icon: Icons.remove,
        enabled: on,
        size: _kStepW,
        step: () => widget.onSetMult(tok.numMult - widget.weightStep),
      ),
      const SizedBox(width: 6), // 降权 | 加权 的轴
      _RepeatBtn(
        icon: Icons.add,
        enabled: on,
        size: _kStepW,
        step: () => widget.onSetMult(tok.numMult + widget.weightStep),
      ),
      const SizedBox(width: 2),
      _weightBtn(
        context,
        '{ }',
        pal.weightUp,
        scheme.onError,
        enabled: on,
        onTap: () => widget.onWrap(true),
        width: _kWrapW,
        height: _kWrapH,
      ),
      const SizedBox(width: 10),
      _denseIcon(
        context,
        Icons.backspace_outlined,
        tooltip: '清除权重',
        enabled: canClear,
        onTap: widget.onClear,
      ),
      const SizedBox(width: 2),
      _denseIcon(
        context,
        Icons.delete_outline,
        color: scheme.error,
        tooltip: '删除',
        onTap: widget.onDelete,
      ),
    ];

    Widget warn() => _denseIcon(
      context,
      Icons.warning_amber_rounded,
      color: scheme.error,
      tooltip: '疑似丢了逗号',
      onTap: () => hintSnack(
        context,
        '「${widget.warning}」可能被误识别为权重,疑似丢了逗号',
        icon: Icons.warning_amber_rounded,
      ),
    );

    return LayoutBuilder(
      builder: (context, c) {
        // 名字至少要能放下两三个字**外加权重后缀**才值得留整段
        final room = c.maxWidth - fixed;
        // +36:名字至少要能露两三个字。再高就会在 393 那类常见宽度上
        // 把名字整个判掉,而那时候明明还塞得下
        final showName = room >= suffixW + 36;
        // 名字放不下但权重放得下:**先保权重**。这一栏就是拿来调权重的,
        // 而「是哪一枚」在正上方的正文里高亮着,名字只是复述。
        final showWeight = !showName && suffixW > 0 && room >= suffixW;
        if (c.maxWidth < fixed) {
          // 连控件都放不下:横向可滚,一个功能都不砍
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.warning != null) ...[warn(), const SizedBox(width: 6)],
                ...controls(),
              ],
            ),
          );
        }
        return Row(
          children: [
            if (widget.warning != null) ...[warn(), const SizedBox(width: 6)],
            if (showName)
              Expanded(child: label())
            else if (showWeight)
              Expanded(child: label(nameless: true))
            else
              const Spacer(),
            ...controls(),
          ],
        );
      },
    );
  }

  /// 关联 chip:英文 + 中文双行(web RelatedTagsRow 同形态),点按插入。
  Widget _relChip(BuildContext context, String tag, VoidCallback onTap) {
    final scheme = context.scheme;
    final trans = translationOf(tag);
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 13, color: scheme.primary),
                  const SizedBox(width: 3),
                  Text(
                    tag,
                    style: context.texts.bodySmall!.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (trans != null) ...[
                const SizedBox(height: 1),
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    trans,
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 10,
                    ),
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

/// 头部:名字 · 热度 · 翻译 · 复制 · 关闭
class _Header extends StatelessWidget {
  const _Header({
    required this.tok,
    required this.count,
    required this.wc,
    required this.onClose,
    required this.renaming,
    required this.nameCtrl,
    required this.nameFocus,
    required this.onStartRename,
    required this.onCommitRename,
    required this.onCancelRename,
  });

  final Tok tok;
  final int? count;
  final Color wc;
  final VoidCallback onClose;

  /// 标题处于行内改名态:整行换成输入框 + 确认/取消。
  final bool renaming;
  final TextEditingController nameCtrl;
  final FocusNode nameFocus;

  /// null = 本模式不给改名入口(点标题没反应)。
  final VoidCallback? onStartRename;
  final VoidCallback onCommitRename;
  final VoidCallback onCancelRename;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    if (renaming) return _renameRow(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onStartRename,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        tok.name.isEmpty ? '标签' : tok.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleMedium!.copyWith(
                          color: wc,
                          fontWeight: FontWeight.w700,
                          decoration: tok.disabled
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                    if (count != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        _formatCount(count!),
                        style: mono(
                          context,
                          size: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    // 可改名时给个笔:不然「标题能点」这件事没人看得出来
                    if (onStartRename != null) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.edit_outlined,
                        size: 14,
                        color: scheme.outline,
                      ),
                    ],
                  ],
                ),
                if (tok.trans != null && tok.trans!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      tok.trans!,
                      style: context.texts.bodyMedium!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (tok.name.isNotEmpty) ...[
          _circleIcon(
            context,
            icon: Icons.travel_explore,
            onTap: () => _openWiki(context, tok.name),
          ),
          const SizedBox(width: 4),
        ],
        _circleIcon(
          context,
          icon: Icons.content_copy,
          onTap: () {
            Clipboard.setData(ClipboardData(text: tok.name));
            hintSnack(context, '已复制标签', icon: Icons.check);
          },
        ),
        const SizedBox(width: 4),
        _circleIcon(context, icon: Icons.close, onTap: onClose),
      ],
    );
  }

  /// 改名态:标题整行换成输入框。回车 = 确认,Esc/✕ = 放弃。
  Widget _renameRow(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: nameCtrl,
            focusNode: nameFocus,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onCommitRename(),
            style: context.texts.titleMedium!.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
            cursorColor: scheme.primary,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _circleIcon(context, icon: Icons.check, onTap: onCommitRename),
        const SizedBox(width: 4),
        _circleIcon(context, icon: Icons.close, onTap: onCancelRename),
      ],
    );
  }

  /// 跳系统浏览器开 Danbooru wiki(web openDanbooru 同款,空格转下划线)。
  Future<void> _openWiki(BuildContext context, String name) async {
    final tag = name.trim().replaceAll(' ', '_');
    final uri = Uri.https('danbooru.donmai.us', '/wiki_pages/$tag');
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && context.mounted) {
      hintSnack(context, '无法打开浏览器', icon: Icons.error_outline);
    }
  }

  static String _formatCount(int n) {
    if (n < 1000) return '';
    if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000).round()}k';
  }
}

// ---- 面板共享控件(单词条 TagPanel 与多选 BatchPanel 共用)----

/// 括号快捷键按钮(`[ ]` / `{ }`,语义色填充)。
Widget _weightBtn(
  BuildContext context,
  String label,
  Color bg,
  Color fg, {
  required bool enabled,
  required VoidCallback onTap,
  double width = 46,
  double height = 38,
}) {
  final scheme = context.scheme;
  return Material(
    color: enabled ? bg : scheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(11),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: enabled ? fg : scheme.outlineVariant,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 操作按钮(清除权重/禁用/删除等,危险=红调)。
Widget _action(
  BuildContext context,
  String label, {
  IconData? icon,
  Widget? leading, // 覆盖 icon 的自定义前导(如加载转圈)
  bool danger = false,
  bool selected = false,
  required bool enabled,
  required VoidCallback onTap,
}) {
  final scheme = context.scheme;
  final fg = !enabled
      ? scheme.outlineVariant
      : selected
      ? scheme.onSecondaryContainer
      : danger
      ? scheme.error
      : scheme.onSurface;
  final bg = selected
      ? scheme.secondaryContainer
      : danger
      ? scheme.error.withValues(alpha: .10)
      : scheme.surfaceContainerHigh;
  return Material(
    color: bg,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (leading != null) ...[
              leading,
              const SizedBox(width: 5),
            ] else if (icon != null) ...[
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                style: context.texts.bodyMedium!.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 圆形小图标按钮(复制/关闭)。
Widget _circleIcon(
  BuildContext context, {
  required IconData icon,
  required VoidCallback onTap,
}) {
  final scheme = context.scheme;
  return Material(
    color: scheme.surfaceContainerHighest,
    shape: const CircleBorder(),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
      ),
    ),
  );
}

/// 精简词条栏里的圆钮([_kTailW])。置灰时不可点,颜色跟着语义走。
Widget _denseIcon(
  BuildContext context,
  IconData icon, {
  required VoidCallback onTap,
  required String tooltip,
  Color? color,
  bool enabled = true,
}) {
  final scheme = context.scheme;
  return Tooltip(
    message: tooltip,
    child: Material(
      color: scheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: _kTailW,
          height: _kTailW,
          child: Icon(
            icon,
            size: 19,
            color: enabled
                ? (color ?? scheme.onSurfaceVariant)
                : scheme.outlineVariant,
          ),
        ),
      ),
    ),
  );
}

/// 多选批量面板 —— **划词多选与多选模式共用同一张**:已选数 + 整体权重
/// + 清除权重 / 禁用 / 删除。
///
/// 面板不认识「怎么选的」:划词是选区扫出的连续区间,多选模式是点 chip 攒出
/// 的集合(可跳选),到这里都只剩已选数与几个能力位。移动不在这里 —— 那是
/// 多选模式画布上点 chip 间隙的 ⊕,就地完成。
///
/// 未选中(只可能出现在多选模式)时按钮全灰,但面板留着占位,不让画布高度
/// 在选/不选之间来回跳。
class BatchPanel extends StatelessWidget {
  const BatchPanel({
    super.key,
    required this.count,
    required this.mult,
    required this.canWeight,
    required this.canDisable,
    required this.anyEnabled,
    this.groupMult,
    this.onSelectGroup,
    this.onUnfold,
    this.foldCount = 0,
    required this.onCopy,
    required this.onWrap,
    required this.onStepMult,
    required this.onClearWeight,
    required this.onToggleDisabled,
    required this.onDelete,
    required this.onClose,
  });

  /// 已选单元数(0 = 多选模式里还没点;划词多选恒 ≥2)。
  final int count;

  /// 面板本地的统一数值权重读数(换一批选中即重置 1.0)。
  final double mult;

  /// 所选里有能加权的连续段(全是零散折叠单元时没有,见 weightRuns)。
  final bool canWeight;

  /// 所选里有散标签(折叠单元不能禁用)。
  final bool canDisable;

  /// 选中里还有启用的 → 动作为「全部禁用」;全禁 → 「全部启用」。
  final bool anyEnabled;

  /// 这一批处在更外层权重组里时的组倍率(与 [onSelectGroup] 同进同退)。
  final double? groupMult;

  /// 把选中扩到整个权重组(扩了才能调组权重);null=没有更外层的组。
  final VoidCallback? onSelectGroup;

  /// 恰好选中一枚折叠段时的「展开」入口。芯片模式里没有正文可点标题,
  /// 解散只能从这儿走;null = 选的不是单枚折叠。
  final VoidCallback? onUnfold;

  /// 该折叠段的成员数(与 [onUnfold] 同进同退):展开会摊出多少枚,先说清楚。
  final int foldCount;

  /// 复制所选(折叠摊平成成员,权重/禁用记号照搬)。
  final VoidCallback onCopy;

  final void Function(bool up) onWrap;
  final void Function(bool up) onStepMult;
  final VoidCallback onClearWeight;
  final VoidCallback onToggleDisabled;
  final VoidCallback onDelete;

  /// 划词:关面板并折叠选区;多选模式:清空选中(模式本身由底栏退出)。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pal = context.editor;
    final has = count > 0;
    final weight = has && canWeight;
    // 没得禁用时读数无意义,标签保持「全部禁用」的默认相,不跳字
    final off = anyEnabled || !canDisable;

    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.select_all,
                  size: 18,
                  color: has ? scheme.primary : scheme.outlineVariant,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    has ? '已选 $count 项' : '点词条可多选',
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w700,
                      color: has ? scheme.onSurface : scheme.outline,
                    ),
                  ),
                ),
                if (has) ...[
                  _circleIcon(
                    context,
                    icon: Icons.content_copy,
                    onTap: onCopy,
                  ),
                  const SizedBox(width: 4),
                  _circleIcon(context, icon: Icons.close, onTap: onClose),
                ],
              ],
            ),
            // 这一批还在更大的权重组里:一键把选中扩到整组,才好调组权重
            // (单词条栏同款入口)。
            if (onSelectGroup != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  children: [
                    Icon(
                      Icons.layers_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '处于权重组 ×${fmtMult(groupMult ?? 1)}',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Material(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(9),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: onSelectGroup,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          child: Text(
                            '选中整组',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (onUnfold != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  children: [
                    Icon(
                      Icons.unfold_more,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '折叠段 · $foldCount 个标签',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Material(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(9),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: onUnfold,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          child: Text(
                            '展开',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            // 权重:括号快捷键(左)· 统一数值加减(右,长按持续步进)
            Row(
              children: [
                Text(
                  '整体',
                  style: context.texts.bodyMedium!.copyWith(
                    color: weight ? scheme.onSurfaceVariant : scheme.outline,
                  ),
                ),
                const SizedBox(width: 12),
                _weightBtn(
                  context,
                  '[ ]',
                  pal.weightDown,
                  scheme.onError,
                  enabled: weight,
                  onTap: () => onWrap(false),
                ),
                const SizedBox(width: 6),
                _weightBtn(
                  context,
                  '{ }',
                  pal.weightUp,
                  scheme.onError,
                  enabled: weight,
                  onTap: () => onWrap(true),
                ),
                const Spacer(),
                _RepeatBtn(
                  icon: Icons.remove,
                  enabled: weight,
                  step: () => onStepMult(false),
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    '×${fmtMult(mult)}',
                    textAlign: TextAlign.center,
                    style: mono(
                      context,
                      size: 16,
                      color: weight ? scheme.onSurface : scheme.outlineVariant,
                    ),
                  ),
                ),
                _RepeatBtn(
                  icon: Icons.add,
                  enabled: weight,
                  step: () => onStepMult(true),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _action(
                    context,
                    '清除权重',
                    enabled: weight,
                    onTap: onClearWeight,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    context,
                    off ? '全部禁用' : '全部启用',
                    icon: off ? Icons.visibility_off : Icons.visibility,
                    enabled: has && canDisable,
                    onTap: onToggleDisabled,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    context,
                    '删除',
                    icon: Icons.delete_outline,
                    danger: true,
                    enabled: has,
                    onTap: onDelete,
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

/// 按住持续步进按钮:点=一步;按住≥350ms 后每 90ms 触发一次 [step],
/// 越按越快(每 5 步周期 −15ms,下限 40ms)。松手或超出按钮范围停止。
class _RepeatBtn extends StatefulWidget {
  const _RepeatBtn({
    required this.icon,
    required this.enabled,
    required this.step,
    this.size = 38,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback step;

  /// 圆钮直径。精简版收到 32(图标跟着缩)。
  final double size;

  @override
  State<_RepeatBtn> createState() => _RepeatBtnState();
}

class _RepeatBtnState extends State<_RepeatBtn> {
  Timer? _hold;
  Timer? _tick;
  int _ticks = 0;

  void _startHold() {
    _hold?.cancel();
    _tick?.cancel();
    _hold = Timer(const Duration(milliseconds: 350), () {
      Haptics.selection();
      _scheduleNext();
    });
  }

  void _scheduleNext() {
    if (!widget.enabled) return _stop();
    // 越按越快
    final period = (90 - (_ticks ~/ 5) * 15).clamp(40, 90);
    _tick = Timer(Duration(milliseconds: period), () {
      widget.step();
      _ticks++;
      _scheduleNext();
    });
  }

  void _stop() {
    _hold?.cancel();
    _tick?.cancel();
    _hold = null;
    _tick = null;
    _ticks = 0;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Listener(
      onPointerDown: (_) {
        if (!widget.enabled) return;
        _startHold();
      },
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.step : null,
        child: Material(
          color: scheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Icon(
              widget.icon,
              size: widget.size >= 38 ? 20 : 18,
              color: widget.enabled ? scheme.onSurface : scheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}
