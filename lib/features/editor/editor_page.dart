import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/editor_theme.dart';
import '../generate/generate_state.dart';
import 'data/local_tag_db.dart';
import 'data/suggestions.dart';
import 'data/tag_completion.dart';
import 'data/tag_translation_service.dart';
import 'editor_models.dart';
import 'editor_state.dart';
import 'widgets/annotated_field.dart';
import 'widgets/completion_bar.dart';
import 'widgets/completion_panel.dart';
import 'widgets/editor_bottom_bar.dart';
import 'widgets/editor_top_bar.dart';
import 'widgets/rich_tag_controller.dart';
import 'widgets/sort_chips_view.dart';
import 'widgets/tag_panel.dart';

/// 提示词编辑器(光标驱动定稿):
/// 表面是可编辑文本域,权重原样内联+上色,翻译绘制层画在词下。
/// **底部只一件事**:光标右邻是词正文→词条栏;是逗号/空隙/行尾或打字中→补全。
class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({super.key, required this.positive, this.characterName});

  final bool positive;
  final String? characterName;

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends ConsumerState<EditorPage>
    with SingleTickerProviderStateMixin {
  final RichTagController _controller = RichTagController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// 正/负切换时编辑区的方向滑入(切负面从右进、切正面从左进)。
  late final AnimationController _tabAnim = AnimationController(
    vsync: this,
    duration: Motion.medium,
  )..value = 1;
  Animation<Offset> _tabSlide = const AlwaysStoppedAnimation(Offset.zero);

  Timer? _debounce;
  bool _muting = false;
  String _prevText = '';
  String? _syncedText;
  String _query = '';
  SuggestResult _result = const SuggestResult();
  int _queryGen = 0; // 递增序号:作废在途异步补全(被后续输入/移光标取代)
  bool _loading = false; // 补全查询进行中(显示加载态)
  bool _sheetOpen = false; // 形态 B(分类竖向列表)弹层是否打开
  Tok? _panelTok; // 光标所在词条(显示词条栏)
  List<String> _related = const []; // 当前词的关联标签(异步拉取)
  String? _relatedFor; // _related 归属的词名(防过期回调窜词)
  bool _relatedLoading = false; // 关联标签拉取中(词条栏「关联」显示转圈)
  bool _sortMode = false; // 排序模式:正文按住即拖词条换位

  EditorNotifier get _notifier => ref.read(editorProvider.notifier);
  late final TagTranslationService _transSvc;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onCtrl);
    // 灌注离线词库全量翻译(否则注音只显示补全零星回填过的词);
    // 灌完刷新注音层/词条栏。幂等,重复进编辑器不重复灌。
    ref.read(localTagDbProvider).warmTagMeta().then((_) {
      if (mounted) _refreshAnnotations();
    });
    // 增强模式的后端翻译通道:回填到货即刷新注音。
    _transSvc = ref.read(tagTranslationServiceProvider);
    _transSvc.addListener(_refreshAnnotations);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final gen = ref.read(generateProvider);
      _notifier.load(
        positive: gen.prompt,
        negative: gen.negativePrompt,
        startPositive: widget.positive,
      );
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _transSvc.removeListener(_refreshAnnotations);
    _tabAnim.dispose();
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 切 tab 的方向滑入:目标是正面(左 tab)从左进,负面(右 tab)从右进。
  void _kickTabSlide(bool toPositive) {
    setState(() {
      _tabSlide = _tabAnim.drive(
        Tween(
          begin: Offset(toPositive ? -.08 : .08, 0),
          end: Offset.zero,
        ).chain(CurveTween(curve: Motion.emphasized)),
      );
    });
    _tabAnim.forward(from: 0);
  }

  /// 翻译数据到货(词库灌注完成/后端回填):重绘注音层与词条栏。
  /// 走 _muting 防经 _onCtrl 触发 _routeCursor 把正在看的补全清掉;
  /// 词条栏开着才重算(与补全互斥,安全)。
  void _refreshAnnotations() {
    if (!mounted) return;
    _muting = true;
    _controller.refresh();
    _muting = false;
    if (_panelTok != null) _routeCursor();
  }

  /// 把注音未命中的词喂给后端翻译通道(增强模式;离线模式 no-op)。
  void _feedTranslation(String text) {
    _transSvc.request([
      for (final t in parseToks(text))
        if (t.trans == null) t.name,
    ]);
  }

  void _save() {
    ref
        .read(generateProvider.notifier)
        .setPrompts(
          positive: _notifier.outputPositive(),
          negative: _notifier.outputNegative(),
        );
  }

  bool _hasCjk(String s) => s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

  bool _rnInside(String text, int off) {
    if (off < 0 || off >= text.length) return false; // 行尾=添加位
    final c = text[off];
    return !(c == ',' || c == '，' || c == ' ' || c == '\t' || c == '\n');
  }

  // ---- provider → controller(切 tab / 撤销 / 载入时回灌)----
  void _syncFromProvider(EditorState next) {
    if (!mounted) return;
    if (next.activeText != _syncedText) {
      _muting = true;
      _controller.value = TextEditingValue(
        text: next.activeText,
        selection: TextSelection.collapsed(offset: next.activeText.length),
      );
      _syncedText = next.activeText;
      _prevText = next.activeText;
      _muting = false;
      _routeCursor();
      _feedTranslation(next.activeText); // 载入/切 tab 的既有文本也问翻译
    }
  }

  void _onCtrl() {
    if (_muting) return;
    final text = _controller.text;
    if (text != _prevText) {
      _prevText = text;
      _syncedText = text;
      _notifier.editActive(text);
      _routeTyping(); // 打字一律走补全
      _feedTranslation(text);
    } else {
      _routeCursor(); // 纯移光标 → 右邻判定
    }
  }

  /// 打字:补全当前词,隐藏词条栏
  void _routeTyping() {
    if (_panelTok != null) setState(() => _panelTok = null);
    _scheduleQuery();
  }

  /// 移光标:右邻是词正文→词条栏;否则清空(底部空)
  void _routeCursor() {
    _clearSuggest();
    final text = _controller.text;
    final off = _controller.selection.baseOffset;
    Tok? tok;
    if (_rnInside(text, off)) {
      final toks = parseToks(text);
      final i = tokIndexAt(text, off, toks);
      if (i >= 0) tok = toks[i];
    }
    if (tok?.segStart != _panelTok?.segStart ||
        tok?.braceLevel != _panelTok?.braceLevel ||
        tok?.numMult != _panelTok?.numMult ||
        tok?.disabled != _panelTok?.disabled ||
        tok?.name != _panelTok?.name ||
        tok?.trans != _panelTok?.trans) {
      setState(() => _panelTok = tok);
    }
    // 关联标签异步拉取(增强模式走后端共现,离线用静态表);换词即重拉,
    // 引擎内有 per-tag 缓存,重复进同一词秒回。拉取期「关联」按钮转圈不置灰。
    final name = tok?.name;
    if (name != null && name != _relatedFor) {
      setState(() {
        _related = const [];
        _relatedFor = name;
        _relatedLoading = true;
      });
      ref.read(tagCompletionProvider).relatedOf(name).then((r) {
        if (!mounted || _relatedFor != name) return;
        setState(() {
          _related = r;
          _relatedLoading = false;
        });
      });
    } else if (name == null && _relatedLoading) {
      setState(() => _relatedLoading = false);
    }
  }

  void _scheduleQuery() {
    _debounce?.cancel();
    final word = _currentWord();
    final trigger = _hasCjk(word) ? word.isNotEmpty : word.length >= 2;
    if (!trigger) {
      _clearSuggest();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      // 注意:不能因 IME composing 有效就 return——手机软键盘(英文预测/中文拼音)
      // 打字期几乎全程维持 composing region,那样整段输入都不会触发补全。
      // 直接用当前词查询;setState 只更新补全面板,不动 controller,不干扰输入法。
      final gen = ++_queryGen;
      // 先进加载态:补全条立即显示「查询中」,不再空白干等
      setState(() {
        _query = word;
        _loading = true;
      });
      final res = await ref.read(tagCompletionProvider).query(word);
      // 被后续输入/移光标取代,或光标已移出该词 → 丢弃这次结果
      if (!mounted || gen != _queryGen || _currentWord() != word) return;
      setState(() {
        _loading = false;
        _result = res;
      });
    });
  }

  /// 补全查询词 = 光标**左侧**的名字部分。在两 tag 间插入时后一个 tag
  /// 会与新输入并成一个 token(`tag1, bl|tag2` → `bltag2`),只取左侧
  /// (`bl`)才不会把后面的英文混进查询、搜个空。
  String _currentWord() {
    final text = _controller.text;
    final off = _controller.selection.baseOffset;
    final toks = parseToks(text);
    final i = tokIndexAt(text, off, toks);
    if (i < 0) return '';
    final t = toks[i];
    final cut = off.clamp(t.nameStart, t.nameEnd);
    return text.substring(t.nameStart, cut);
  }

  void _clearSuggest() {
    _debounce?.cancel();
    _queryGen++; // 使在途异步补全作废
    if (_query.isEmpty && _result.isEmpty && !_loading) return;
    setState(() {
      _query = '';
      _result = const SuggestResult();
      _loading = false;
    });
  }

  /// 形态 A → B:收键盘,以底部弹层(真正的上滑/下滑物理)呈现分类竖向列表。
  /// 弹层内容用当前查询快照(键盘已收,列表冻结);行主体点按=选中并关闭,
  /// `+`=连续插入不关闭,抓手/底部/下滑=关闭。关闭后唤回键盘。
  Future<void> _expand() async {
    if (_sheetOpen || _query.isEmpty || _result.isEmpty) return;
    _sheetOpen = true;
    _focus.unfocus();
    final size = MediaQuery.of(context).size;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .18),
      builder: (ctx) => Theme(
        data: editorTheme(),
        child: CompletionPanel(
          query: _query,
          result: _result,
          maxHeight: size.height * 0.5,
          onPick: (s) {
            Navigator.of(ctx).pop();
            _pick(s);
          },
          onInsert: _insertAppend,
          onCollapse: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
    _sheetOpen = false;
    if (mounted) _focus.requestFocus(); // 关闭即回键盘
  }

  /// `+` 连续插入:把建议追加为当前词后的新标签,弹层保持打开、结果冻结。
  /// 走独立路径(不经 [_routeCursor]),避免清掉正在浏览的补全列表。
  void _insertAppend(Suggestion s) {
    final text = _controller.text;
    final t = _tokAtCursor();
    final at = (t?.segEnd ?? _controller.selection.baseOffset).clamp(
      0,
      text.length,
    );
    final ins = s.text;
    final newText = '${text.substring(0, at)}, $ins${text.substring(at)}';
    final cursor = at + 2 + ins.length;
    _muting = true;
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _prevText = newText;
    _syncedText = newText;
    _muting = false;
    _notifier.editActive(newText, structural: true);
    HapticFeedback.selectionClick();
    // _query / _result 原样保留,弹层列表不跳
  }

  /// 程序化改文本(补全/权重/删除),同步撤销与路由
  void _applyText(String text, int cursor, {bool structural = true}) {
    _muting = true;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor.clamp(0, text.length)),
    );
    _prevText = text;
    _syncedText = text;
    _muting = false;
    _notifier.editActive(text, structural: structural);
    _routeCursor();
  }

  // ---- 补全:替换光标所在词的名字(保留其权重语法)----
  /// 若 [at] 之后(跳过空格)没有分隔(逗号/换行),补上 `, ` 并把光标放
  /// 其后——选中补全即可直接打下一枚(web formatAutocompleteTagInsertion
  /// 同款追加);已有分隔则原样、光标留在词末。
  (String, int) _withTrailingComma(String text, int at) {
    var k = at;
    while (k < text.length && (text[k] == ' ' || text[k] == '\t')) {
      k++;
    }
    final sep =
        k < text.length &&
        (text[k] == ',' || text[k] == '，' || text[k] == '\n');
    if (sep) return (text, at);
    return (text.replaceRange(at, at, ', '), at + 2);
  }

  void _pick(Suggestion s) {
    if (s.natural) {
      _pickNatural(s);
      return;
    }
    final text = _controller.text;
    final off = _controller.selection.baseOffset;
    final toks = parseToks(text);
    final i = tokIndexAt(text, off, toks);
    final ins = s.insertText ?? s.text;
    if (i < 0) {
      final replaced = text.replaceRange(off, off, ins);
      final (withComma, cursor) = _withTrailingComma(
        replaced,
        off + ins.length,
      );
      _applyText(withComma, cursor);
      _focus.requestFocus();
      return;
    }
    final t = toks[i];
    // 光标右侧的名字残余:两 tag 间插入时后一个 tag 被并入了当前 token,
    // 拆开成「ins, 后一tag」;否则(残余为空)= 常规整词替换 + 尾部补逗号。
    final cut = off.clamp(t.nameStart, t.nameEnd);
    final rightName = text.substring(cut, t.nameEnd).trimLeft();
    if (rightName.isEmpty) {
      final newText = text.replaceRange(t.nameStart, t.nameEnd, ins);
      final end = t.segEnd + (ins.length - (t.nameEnd - t.nameStart));
      final (withComma, cursor) = _withTrailingComma(newText, end);
      _applyText(withComma, cursor);
    } else {
      final newText = text.replaceRange(
        t.nameStart,
        t.nameEnd,
        '$ins, $rightName',
      );
      // 光标落到「ins, 」之后、后一 tag 之前,便于继续插入
      _applyText(newText, t.nameStart + ins.length + 2);
    }
    _focus.requestFocus();
  }

  /// 「翻译为英文」行:异步把当前中文词整句翻成英文短句,替换之。
  Future<void> _pickNatural(Suggestion s) async {
    setState(() => _loading = true);
    final en = await ref.read(tagCompletionProvider).translateNatural(s.text);
    if (!mounted) return;
    setState(() => _loading = false);
    final ins = en?.trim() ?? '';
    if (ins.isEmpty) return;
    final text = _controller.text;
    final off = _controller.selection.baseOffset;
    final toks = parseToks(text);
    final i = tokIndexAt(text, off, toks);
    final (String replaced, int end) = i >= 0
        ? () {
            final t = toks[i];
            final newText = text.replaceRange(t.nameStart, t.nameEnd, ins);
            // 落到整段末(名字末可能在权重括号内,在那里补逗号会插进括号)
            return (newText, t.segEnd + ins.length - (t.nameEnd - t.nameStart));
          }()
        : (text.replaceRange(off, off, ins), off + ins.length);
    final (withComma, cursor) = _withTrailingComma(replaced, end);
    _applyText(withComma, cursor);
    _focus.requestFocus();
  }

  /// 排序模式开关:进入=收键盘/清补全与词条栏,正文按住即拖;
  /// 退出=唤回键盘。每次拖动落一步撤销。
  void _toggleSort() {
    if (!_sortMode && parseToks(_controller.text).length < 2) return;
    final entering = !_sortMode;
    if (entering) {
      _focus.unfocus();
      _clearSuggest();
    }
    setState(() {
      _sortMode = entering;
      if (entering) _panelTok = null;
    });
    if (!entering) _focus.requestFocus();
  }

  /// 排序落地(排序层松手回调):槽位法重排,保留分隔/换行排版。
  void _reorderTok(int from, int to) {
    final next = reorderToks(_controller.text, from, to);
    _applyText(next, _controller.selection.baseOffset.clamp(0, next.length));
  }

  // ---- 词条栏操作(都改文本)----
  Tok? _tokAtCursor() {
    final text = _controller.text;
    final toks = parseToks(text);
    final i = tokIndexAt(text, _controller.selection.baseOffset, toks);
    return i >= 0 ? toks[i] : null;
  }

  void _wrap(bool up) {
    final t = _tokAtCursor();
    if (t == null) return;
    _applyText(wrapBracket(_controller.text, t, up: up), t.coreStart + 1);
  }

  void _setMult(double m) {
    final t = _tokAtCursor();
    if (t == null) return;
    // 拖动/连点合并入撤销栈,不逐步刷屏
    _applyText(
      setTokMult(_controller.text, t, m),
      t.innerStart,
      structural: false,
    );
  }

  void _clearWeight() {
    final t = _tokAtCursor();
    if (t == null) return;
    _applyText(clearWeight(_controller.text, t), t.coreStart);
  }

  /// 关联标签:插到当前词之后,光标留在原词条上(面板不跳)
  void _addRelated(String tag) {
    final text = _controller.text;
    final t = _tokAtCursor();
    final at = t?.segEnd ?? text.length;
    final newText = '${text.substring(0, at)}, $tag${text.substring(at)}';
    _applyText(newText, t?.segStart ?? (at + 2 + tag.length), structural: true);
  }

  void _toggleDisabled() {
    final t = _tokAtCursor();
    if (t == null) return;
    _applyText(toggleTokDisabled(_controller.text, t), t.segStart);
  }

  void _deleteCurrent() {
    final t = _tokAtCursor();
    if (t == null) return;
    final (text, cursor) = deleteTok(_controller.text, t);
    _applyText(text, cursor);
    _focus.requestFocus();
  }

  /// 关闭词条栏(下次移光标进词内会再出现)
  void _closePanel() {
    if (_panelTok == null) return;
    setState(() => _panelTok = null);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<EditorState>(editorProvider, (prev, next) {
      if (prev != null && prev.activePositive != next.activePositive) {
        _kickTabSlide(next.activePositive);
      }
      _syncFromProvider(next);
    });

    return Theme(
      data: editorTheme(),
      child: Builder(
        builder: (context) => PopScope(
          // 排序模式中返回键先退出模式,再按一次才离开编辑器
          canPop: !_sortMode,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              _save();
            } else if (_sortMode) {
              _toggleSort();
            }
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  EditorTopBar(onBack: () => Navigator.of(context).maybePop()),
                  Expanded(
                    // 排序模式切换成真 chip 流视图;编辑态是注音富文本。
                    // 切正/负时编辑区随方向轻滑 + 淡入(单实例,不复制
                    // TextField——controller/focus 不能同时挂两棵树)
                    child: _sortMode
                        ? SortChipsView(
                            controller: _controller,
                            onReorder: _reorderTok,
                          )
                        : ClipRect(
                            child: SlideTransition(
                              position: _tabSlide,
                              child: FadeTransition(
                                opacity: _tabAnim.drive(
                                  Tween(begin: .25, end: 1.0),
                                ),
                                child: AnnotatedField(
                                  controller: _controller,
                                  focusNode: _focus,
                                  scrollController: _scroll,
                                  hint: '输入标签,逗号或换行分隔 · 光标进词内改字 · 权重原样如 {tag}',
                                ),
                              ),
                            ),
                          ),
                  ),
                  // dock 入场:淡入 + 轻微上滑(高度瞬时占位,不撑盒子,避免橡皮筋)
                  AnimatedSwitcher(
                    duration: Motion.fast,
                    switchInCurve: Motion.emphasized,
                    switchOutCurve: Motion.standard,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.bottomCenter,
                      children: [...previous, ?current],
                    ),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.06),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: _dock(),
                  ),
                  EditorBottomBar(onSort: _toggleSort, sortActive: _sortMode),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dock() {
    // key 稳定=同一形态内更新不重播入场动画(如长按连续调权重);切形态才动画
    if (_sortMode) {
      final scheme = context.scheme;
      return Container(
        key: const ValueKey('dock-sort'),
        width: double.infinity,
        color: scheme.surface,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Text(
          '点选词条 → 点间隙 ⊕ 插入 · 点别的词改选 · 点自身或空白取消',
          textAlign: TextAlign.center,
          style: context.texts.labelSmall!.copyWith(color: scheme.outline),
        ),
      );
    }
    if (_query.isNotEmpty) {
      return CompletionBar(
        key: const ValueKey('dock-completion'),
        query: _query,
        result: _result,
        loading: _loading,
        onPick: _pick,
        onAddRaw: _clearSuggest,
        onExpand: _expand,
        onClose: _clearSuggest,
      );
    }
    if (_panelTok != null) {
      final tok = _panelTok!;
      return TagPanel(
        key: const ValueKey('dock-tag'),
        tok: tok,
        count: countOf(tok.name),
        related: tok.name == _relatedFor ? _related : const [],
        relatedLoading: tok.name == _relatedFor && _relatedLoading,
        onWrap: _wrap,
        onSetMult: _setMult,
        onClear: _clearWeight,
        onToggleDisabled: _toggleDisabled,
        onDelete: _deleteCurrent,
        onAddRelated: _addRelated,
        onClose: _closePanel,
      );
    }
    return const SizedBox.shrink(key: ValueKey('dock-empty'));
  }
}
