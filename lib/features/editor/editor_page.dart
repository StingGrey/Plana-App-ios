import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/editor_theme.dart';
import '../generate/generate_state.dart';
import '../generate/widgets/common.dart' show hintSnack;
import 'data/local_tag_db.dart';
import 'data/suggestions.dart';
import 'data/tag_completion.dart';
import 'data/tag_translation_service.dart';
import 'editor_models.dart';
import 'editor_settings.dart';
import 'editor_state.dart';
import 'widgets/annotated_field.dart';
import 'widgets/completion_bar.dart';
import 'widgets/completion_panel.dart';
import 'widgets/editor_bottom_bar.dart';
import 'widgets/editor_settings_sheet.dart';
import 'widgets/editor_top_bar.dart';
import 'widgets/rich_tag_controller.dart';
import 'widgets/sort_chips_view.dart';
import 'widgets/tag_panel.dart';
import '../../core/util/haptics.dart';

/// 提示词编辑器(光标驱动定稿):
/// 表面是可编辑文本域,权重原样内联+上色,翻译绘制层画在词下。
/// **底部只一件事**:光标点在词里(含多词名内部空格)→词条栏;
/// 逗号/词条间空隙/行尾或打字中→补全。
class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({super.key, required this.positive, this.charId});

  final bool positive;

  /// 编辑目标:null = 创作页主提示词,否则 = 该 id 的角色提示词。
  final String? charId;

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
  TextSelection _prevSel = const TextSelection.collapsed(offset: -1);
  String? _syncedText;
  String _query = '';
  SuggestResult _result = const SuggestResult();
  int _queryGen = 0; // 递增序号:作废在途异步补全(被后续输入/移光标取代)
  bool _loading = false; // 补全查询进行中(显示加载态)
  bool _translating = false; // 「翻译为英文」LLM 在途(补全条切「翻译中」态)
  bool _sheetOpen = false; // 形态 B(分类竖向列表)弹层是否打开
  Tok? _panelTok; // 光标所在词条(显示词条栏)
  (int, int)? _multiRange; // 划词多选覆盖的词条区间 [first, last](批量面板)
  double _multiMult = 1.0; // 批量面板的统一数值权重读数
  List<String> _related = const []; // 当前词的关联标签(异步拉取)
  String? _relatedFor; // _related 归属的词名(防过期回调窜词)
  bool _relatedLoading = false; // 关联标签拉取中(词条栏「关联」显示转圈)
  bool _sortMode = false; // 多选模式:正文换成 chip 流,点选后批量移动/加权/删除
  Set<int> _sortSel = {}; // 多选模式已选顶层单元下标
  double _sortMult = 1.0; // 多选模式批量面板的统一数值权重读数
  String? _charName; // 编辑角色时的名字(顶栏标题);主提示词会话为 null

  EditorNotifier get _notifier => ref.read(editorProvider.notifier);
  late final TagTranslationService _transSvc;

  /// 编辑中退后台:先冲刷编辑器回写,再让工作台立即落盘——
  /// 覆盖「切走后进程被杀」,不依赖防抖计时器有没有走完。
  AppLifecycleListener? _lifecycle;

  /// 编辑器行为开关(设置弹层里改,即时生效);载入前用默认值(全开)。
  EditorSettings get _settings =>
      ref.read(editorSettingsProvider).value ?? const EditorSettings();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (!mounted) return;
        if (s == AppLifecycleState.inactive || s == AppLifecycleState.paused) {
          _notifier.flushWriteBack();
          ref.read(appStoresProvider).flushNow();
        }
      },
    );
    _controller.addListener(_onCtrl);
    // 灌注离线词库全量翻译(否则注音只显示补全零星回填过的词);
    // 灌完刷新注音层/词条栏。幂等,重复进编辑器不重复灌。
    ref.read(localTagDbProvider).warmTagMeta().then((_) {
      if (mounted) _refreshAnnotations();
    });
    // 增强模式的后端翻译通道:回填到货即刷新注音。
    _transSvc = ref.read(tagTranslationServiceProvider);
    _transSvc.addListener(_refreshAnnotations);
    // 编辑目标进页面即钉死。角色名只读一次:名字是 app 内部写的
    // (自动编号 / 导入带入),会话中不会变,不必挂 watch。
    final id = widget.charId;
    final hit = [
      for (final c in ref.read(generateProvider).characters)
        if (c.id == id) c,
    ];
    final char = hit.isEmpty ? null : hit.first;
    _charName = char?.name;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final gen = ref.read(generateProvider);
      // 角色会话即使没命中(角色已被删)也**不**退回主提示词:那正是
      // 这个页面从前的 bug——回写会静默盖掉用户的主提示词。
      // 载入原文草稿(带回禁用/折叠);草稿过期(提示词被编辑器之外改过)
      // 时 pickEditorText 自动退回定稿。
      _notifier.load(
        positive: id == null
            ? pickEditorText(gen.promptRaw, gen.prompt)
            : pickEditorText(char?.positiveRaw ?? '', char?.positive ?? ''),
        negative: id == null
            ? pickEditorText(gen.negativePromptRaw, gen.negativePrompt)
            : pickEditorText(char?.negativeRaw ?? '', char?.negative ?? ''),
        startPositive: widget.positive,
        charId: id,
      );
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
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

  void _save() => _notifier.flushWriteBack();

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
      _prevSel = _controller.selection;
      _muting = false;
      _routeCursor();
      _feedTranslation(next.activeText); // 载入/切 tab 的既有文本也问翻译
    }
  }

  void _onCtrl() {
    if (_muting) return;
    final prevSel = _prevSel;
    _prevSel = _controller.selection;
    final text = _controller.text;
    if (text != _prevText) {
      if (_guardFoldEdit(text)) return; // 折叠被啃 → 改判为整只删,已自行落地
      _prevText = text;
      _syncedText = text;
      _notifier.editActive(text);
      _routeTyping(); // 打字一律走补全
      _feedTranslation(text);
    } else {
      // 双击/长按选词 → 扩到整枚词条;改完选区会再进一次监听走 _routeCursor
      if (_captureTagSelection(prevSel)) return;
      if (_snapCaretOutOfFold()) return;
      _routeCursor(); // 纯移光标 → 右邻判定
    }
  }

  // ---- 折叠在正文里的交互 ----
  // 正文里折叠只是占位符 `<#名字>`(折叠体在 EditorState.foldBodies 表里,
  // 不进 TextField)。一次性:单击标题热区即解散(占位符原地换成内容)。
  // 占位符是原子整体:光标不进内部、退格落在上面整只删——啃烂占位符会留下
  // 解析不出的残渣。多字删除是主动划选,不拦(删掉占位符 = 删掉折叠,合理)。

  Map<String, String> get _foldBodies => ref.read(editorProvider).foldBodies;

  /// 单击折叠标题:一次性解散,占位符原地替换为折叠体。
  void _unfoldByName(String name) {
    for (final r in parseFoldRefs(_controller.text, _foldBodies)) {
      if (r.name != name) continue;
      _applyText(unfoldRef(_controller.text, r, _foldBodies), r.start);
      // 展开的意图是「摊开看」,不是「查首个词」:光标落在展开内容的
      // 头一个词上,路由会把它的词条面板弹出来 —— 压掉。
      if (_panelTok != null) setState(() => _panelTok = null);
      Haptics.selection();
      return;
    }
  }

  /// 光标落进占位符内部 → 吸到最近的边缘。处理了返回 true。
  ///
  /// **必须 _muting 包住 selection 写入**:改 selection 会同步 notifyListeners →
  /// 重入本 _onCtrl。不 mute 虽不至死循环(吸附后 off 已在边缘不再匹配),但会
  /// 平白多走一轮路由;mute 后手动 _routeCursor 归位 dock,干净一次到位。
  bool _snapCaretOutOfFold() {
    final sel = _controller.selection;
    if (!sel.isValid || !sel.isCollapsed) return false;
    final off = sel.baseOffset;
    for (final r in parseFoldRefs(_controller.text, _foldBodies)) {
      if (off <= r.start || off >= r.end) continue;
      _muting = true;
      final to = (off - r.start) < (r.end - off) ? r.start : r.end;
      _prevSel = TextSelection.collapsed(offset: to);
      _controller.selection = _prevSel;
      _muting = false;
      _routeCursor();
      return true;
    }
    return false;
  }

  /// 单字删除若落在占位符上,改判为整只删除。删除点 d 用闭区间
  /// (`>= r.start`):退格删的是 d 左边那个字,d 落在 start 时删的正是
  /// `<`,该算命中。
  bool _guardFoldEdit(String next) {
    if (next.length != _prevText.length - 1) return false;
    final d = _controller.selection.baseOffset;
    if (d < 0) return false;
    for (final r in parseFoldRefs(_prevText, _foldBodies)) {
      if (d >= r.start && d < r.end) {
        final (out, cursor) = deleteFoldRef(_prevText, r);
        _applyText(out, cursor);
        Haptics.selection();
        return true;
      }
    }
    return false;
  }

  /// 双击/长按选词的 tag 捕获(web handleDoubleClick 同款):
  /// 从折叠光标一步变出的、落在单一词条内的子选区,扩成整枚词条
  /// (含权重语法,即 [segStart, segEnd))。已有选区上继续拖手柄
  /// (prev 已展开)不干预,用户仍可自由精调。
  bool _captureTagSelection(TextSelection prev) {
    final sel = _controller.selection;
    if (!sel.isValid || sel.isCollapsed) return false;
    if (prev.isValid && !prev.isCollapsed) return false;
    final text = _controller.text;
    final toks = parseToks(text);
    final i = tokIndexAt(text, sel.start, toks);
    if (i < 0) return false;
    final t = toks[i];
    if (sel.end > t.segEnd) return false; // 跨词条(交给多选/自由选区)
    if (sel.start == t.segStart && sel.end == t.segEnd) return false; // 已整枚
    _prevSel = TextSelection(baseOffset: t.segStart, extentOffset: t.segEnd);
    _controller.selection = _prevSel;
    return true;
  }

  /// 打字:补全当前词,隐藏词条栏/批量面板
  void _routeTyping() {
    if (_panelTok != null || _multiRange != null) {
      setState(() {
        _panelTok = null;
        _multiRange = null;
      });
    }
    _scheduleQuery();
  }

  /// 移光标:点在词里(右邻是词正文,或多词标签名内部的空格)→词条栏;
  /// 逗号/词条间空隙/行尾→清空(那是添加位)。设置里关掉则恒不出。
  /// 选区盖住 ≥2 枚词条时 dock 换成批量面板(web multiSelectPanel 移植)。
  void _routeCursor() {
    _clearSuggest();
    final text = _controller.text;
    final sel = _controller.selection;
    if (sel.isValid && !sel.isCollapsed) {
      final toks = parseToks(text);
      var first = -1, last = -1;
      for (var i = 0; i < toks.length; i++) {
        if (toks[i].segEnd > sel.start && toks[i].segStart < sel.end) {
          if (first < 0) first = i;
          last = i;
        }
      }
      if (first >= 0 && last > first) {
        setState(() {
          _panelTok = null;
          // 新进多选才重算起步读数;同一批里连点 ± 保持读数连贯
          if (_multiRange == null) {
            _multiMult = _sharedMult(toks, {
              for (var i = first; i <= last; i++) i,
            });
          }
          _multiRange = (first, last);
        });
        return;
      }
    }
    if (_multiRange != null) setState(() => _multiRange = null);
    final off = _controller.selection.baseOffset;
    Tok? tok;
    if (_settings.enableTagPanel) {
      final toks = parseToks(text);
      final i = tokIndexAt(text, off, toks);
      if (i >= 0 &&
          // 右邻是词正文,或落在多词标签名**内部**的空格上(long| hair)——
          // 都算点在词里;词条间空隙/逗号前仍是添加位,不出面板。
          (_rnInside(text, off) ||
              (off > toks[i].nameStart && off < toks[i].nameEnd))) {
        tok = toks[i];
      }
      // 折叠占位符不是词条:词条栏对它没有任何有意义的操作
      // (权重/禁用/删除该走整块语义),点标题解散才是它的交互。
      if (tok case final Tok hit) {
        for (final r in parseFoldRefs(text, _foldBodies)) {
          if (r.start == hit.segStart && r.end == hit.segEnd) {
            tok = null;
            break;
          }
        }
      }
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
    if (!_settings.enableCompletion) {
      _clearSuggest();
      return;
    }
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
      var res = await ref.read(tagCompletionProvider).query(word);
      // 实体建议关闭:只留标签行(引擎缓存不区分设置,出口过滤)
      if (!_settings.entitySuggest) res = SuggestResult(tags: res.tags);
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
        data: editorTheme(ctx),
        child: CompletionPanel(
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

  /// 编辑器设置弹层:开关即时生效(经 build 的 ref.listen 反映到当前会话)。
  Future<void> _openSettings() async {
    _focus.unfocus();
    await showModalBottomSheet<void>(
      context: context,
      // 内容超过默认 9/16 屏高上限,自控高度(弹层内部滚动 + 85% 封顶)
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .18),
      builder: (ctx) =>
          Theme(data: editorTheme(ctx), child: const EditorSettingsSheet()),
    );
    if (mounted && !_sortMode) _focus.requestFocus();
  }

  /// 建议的落地文本。画师串 / OC 标签组这类**一次带进来一整组**的建议
  /// 自动折叠:内容注册进折叠表,正文只落占位符 `<#名字>`;单枚标签照常平铺。
  ///
  /// 两处不折:
  /// - 角色提示词(charId != null)—— 折叠只服务主提示词;
  /// - 落点不干净([plainSlot] = false,即被 `{}` / `N::` / `~` 包着)——
  ///   占位符要独占一段才是折叠单元,塞半截词里徒增乱子。
  String _insertTextOf(Suggestion s, {required bool plainSlot}) {
    final ins = s.insertText ?? s.text;
    if (widget.charId != null || !plainSlot) return ins;
    final body = ins.trim();
    if (parseToks(body).length < 2) return ins; // 单枚不折,折了徒增记号
    final name = _notifier.registerFold(s.text, body);
    return foldRefLiteral(name);
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
    // 追加到词条之后,落点天然干净
    final ins = _insertTextOf(s, plainSlot: true);
    final newText = '${text.substring(0, at)}, $ins${text.substring(at)}';
    final cursor = at + 2 + ins.length;
    _muting = true;
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _prevText = newText;
    _syncedText = newText;
    _prevSel = _controller.selection;
    _muting = false;
    _notifier.editActive(newText, structural: true);
    _feedTranslation(newText); // 同 _applyText:_muting 压掉了 _onCtrl,得自己喂
    Haptics.selection();
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
    _prevSel = _controller.selection;
    _muting = false;
    _notifier.editActive(text, structural: structural);
    // 打字走 _onCtrl 会喂翻译,这条路径 _muting 压掉了 _onCtrl,必须自己喂 ——
    // 否则**所有**程序化改文本(折叠展开/补全插入/多选批量)带进来的新词
    // 都问不到后端翻译,只能退出重进页面才补上(_syncFromProvider 那次)。
    // 折叠展开尤其明显:折叠体里的词此前只在旁路表里,正文从没见过它们。
    // request() 内部按「已问过/已有译文」去重,重复调很便宜。
    _feedTranslation(text);
    _routeCursor();
  }

  // ---- 补全:替换光标所在词的名字(保留其权重语法)----
  /// 若 [at] 之后(跳过空格)没有分隔(逗号/换行),补上 `, ` 并把光标放
  /// 其后——选中补全即可直接打下一枚(web formatAutocompleteTagInsertion
  /// 同款追加);已有分隔则原样、光标留在词末。设置里可关。
  (String, int) _withTrailingComma(String text, int at) {
    if (!_settings.autoComma) return (text, at);
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
    if (i < 0) {
      // 光标在逗号/空隙上:落点干净
      final ins = _insertTextOf(s, plainSlot: true);
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
      // 整枚替换:被替换的词条本身没有权重/禁用语法时,落点才算干净
      final ins = _insertTextOf(
        s,
        plainSlot: t.segStart == t.nameStart && t.segEnd == t.nameEnd,
      );
      final newText = text.replaceRange(t.nameStart, t.nameEnd, ins);
      final end = t.segEnd + (ins.length - (t.nameEnd - t.nameStart));
      final (withComma, cursor) = _withTrailingComma(newText, end);
      _applyText(withComma, cursor);
    } else {
      // 拆分现有 token:落点夹在半截词里,不折
      final ins = _insertTextOf(s, plainSlot: false);
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
  /// LLM 要等几秒:等待期补全条切「翻译中」态;定位用点击时的快照,
  /// 等待中文本被改动则丢弃结果(落下去会毁掉新输入)。
  Future<void> _pickNatural(Suggestion s) async {
    if (_translating) return; // 在途,忽略重复点击
    final text = _controller.text;
    final off = _controller.selection.baseOffset;
    setState(() => _translating = true);
    final en = await ref.read(tagCompletionProvider).translateNatural(s.text);
    if (!mounted) return;
    setState(() => _translating = false);
    final ins = en?.trim() ?? '';
    if (ins.isEmpty) {
      hintSnack(context, '翻译失败,稍后再试', icon: Icons.error_outline);
      return;
    }
    if (_controller.text != text) return;
    // 文本没变,快照偏移仍有效;光标挪走也仍替换当初点击的那个词。
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

  /// 多选模式开关:进入=收键盘/清补全与词条栏,正文换成 chip 流;
  /// 退出=唤回键盘并清空选中。每次操作落一步撤销。
  void _toggleSort() {
    if (!_sortMode && parseToks(_controller.text).length < 2) return;
    final entering = !_sortMode;
    if (entering) {
      _focus.unfocus();
      _clearSuggest();
    }
    setState(() {
      _sortMode = entering;
      _sortSel = {};
      _sortMult = 1.0;
      if (entering) {
        _panelTok = null;
        _multiRange = null;
      }
    });
    if (!entering) _focus.requestFocus();
  }

  /// 换一批选中:重算起步读数(批量数值是**统一设定**不是相对加减,留着上
  /// 一批的读数会指着不相干的词)。
  void _setSortSel(Set<int> next) => setState(() {
    _sortSel = next;
    _sortMult = _sharedMult(parseToks(_controller.text), next);
  });

  /// 一批词条的起步读数:全员同处一个权重组(如刚点过「选中整组」)时从组
  /// 倍率起步,调整才是在原权重基础上加减;各不相同或本无组 → 从 1 起。
  /// 两处多选共用,顶层单元与词条一一对应,下标可直接用。
  double _sharedMult(List<Tok> toks, Iterable<int> sel) {
    double? gm;
    for (final i in sel) {
      if (i < 0 || i >= toks.length) continue;
      final m = toks[i].groupMult;
      if (gm == null) {
        gm = m;
      } else if ((m - gm).abs() > 0.0001) {
        return 1.0;
      }
    }
    if (gm == null || (gm - 1).abs() <= 0.0001) return 1.0;
    return (gm * 100).roundToDouble() / 100;
  }

  /// 「选中整组」的落点:覆盖这批单元、且**还能带进新单元**的最外层权重组
  /// → (组区间, 该组盖住的全部单元)。只多包住几个记号字符不算 —— 那样点了
  /// 等于没点,按钮就不该出现。
  (WeightSpan, Set<int>)? _groupSelOf(List<TopUnit> units, Set<int> sel) {
    if (sel.isEmpty) return null;
    var a = -1, b = -1;
    for (final i in sel) {
      if (a < 0 || units[i].start < a) a = units[i].start;
      if (units[i].end > b) b = units[i].end;
    }
    final spans = <WeightSpan>[];
    parseToks(_controller.text, weightSpans: spans);
    (WeightSpan, Set<int>)? best;
    for (final s in spans) {
      if (s.start > a || s.end < b) continue;
      final covered = {
        for (var i = 0; i < units.length; i++)
          if (units[i].end > s.start && units[i].start < s.end) i,
      };
      if (covered.length <= sel.length) continue;
      if (best == null || s.end - s.start > best.$1.end - best.$1.start) {
        best = (s, covered);
      }
    }
    return best;
  }

  /// 复制所选:折叠摊平成成员(占位符出了这个 app 没意义),其余原文照搬,
  /// 权重/禁用记号一并带走,逗号拼接。
  void _copyUnits(Set<int> sel) {
    final text = _controller.text;
    final units = topLevelUnits(text, _foldBodies);
    final ordered =
        sel.where((i) => i >= 0 && i < units.length).toList()..sort();
    final parts = [
      for (final i in ordered)
        if (units[i].isFold)
          _foldBodies[units[i].fold!.name] ?? ''
        else
          text.substring(units[i].start, units[i].end),
    ];
    final out = [
      for (final p in parts)
        if (p.trim().isNotEmpty) p.trim(),
    ].join(', ');
    if (out.isEmpty) return;
    Clipboard.setData(ClipboardData(text: out));
    hintSnack(context, '已复制 ${ordered.length} 项', icon: Icons.check);
  }

  /// 多选移动落地:所选顶层单元整批搬到间隙 [to]。折叠占位符作为一整块
  /// 移动;保留分隔/换行排版。搬完清空选中(这一批已经放到位了)。
  void _moveUnits(int to) {
    final next = moveUnits(_controller.text, _foldBodies, _sortSel, to);
    _setSortSel({});
    _applyText(next, _controller.selection.baseOffset.clamp(0, next.length));
  }

  /// 批量禁用/启用的目标态:所选里**第一枚散标签**的反态,全体向它对齐
  /// (web 同款语义);全是折叠 → null,没得禁用。两处多选共用。
  bool? _disableTarget(List<TopUnit> units, Iterable<int> sel) {
    final ordered = sel.toList()..sort();
    for (final i in ordered) {
      if (i < 0 || i >= units.length) continue;
      if (units[i].tok case final t?) return !t.disabled;
    }
    return null;
  }

  // ---- 多选模式批量操作(chip 点选;选中保留以便接着操作)----
  // 与划词多选走同一套单元级操作,差别只在选中集可以跳选 —— 权重按连续段
  // 分段落地(batchWrapUnits 等),没选中的词不会被卷进同一层括号。

  /// 改完文本刷新面板:chip 流挂着 controller 会自己重画,dock 上的面板读的
  /// 是正文算出来的能力位(可加权/可禁用/有启用项),得跟着重建一次。
  void _applySort(String next) {
    _applyText(next, _controller.selection.baseOffset);
    if (mounted) setState(() {});
  }

  void _sortWrap(bool up) {
    if (_sortSel.isEmpty) return;
    _applySort(batchWrapUnits(_controller.text, _foldBodies, _sortSel, up: up));
  }

  void _sortStepMult(bool up) {
    if (_sortSel.isEmpty) return;
    final step = _settings.weightStep;
    final next =
        ((_sortMult + (up ? step : -step)) * 100).roundToDouble() / 100;
    _sortMult = next;
    _applySort(batchSetMultUnits(_controller.text, _foldBodies, _sortSel, next));
  }

  void _sortClearWeight() {
    if (_sortSel.isEmpty) return;
    _sortMult = 1.0;
    _applySort(batchClearWeightUnits(_controller.text, _foldBodies, _sortSel));
  }

  void _sortToggleDisabled() {
    final units = topLevelUnits(_controller.text, _foldBodies);
    final target = _disableTarget(units, _sortSel);
    if (target == null) return; // 全是折叠,没得禁用
    _applySort(
      setUnitsDisabled(_controller.text, _foldBodies, _sortSel, target),
    );
  }

  void _sortDelete() {
    final (text, cursor) = deleteUnits(_controller.text, _foldBodies, _sortSel);
    _setSortSel({});
    _applyText(text, cursor);
  }

  // ---- 划词多选批量操作(dock 批量面板;逐词应用,应用后保持选区)----

  /// 批量改文本落地:重新覆盖同一批词条(数量不变的操作),面板保持。
  void _applyBatchKeep(String newText) {
    final r = _multiRange;
    if (r == null) return;
    final toks = parseToks(newText);
    if (toks.isEmpty) return;
    final last = r.$2 < toks.length ? r.$2 : toks.length - 1;
    final first = r.$1 <= last ? r.$1 : last;
    _muting = true;
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: toks[first].segStart,
        extentOffset: toks[last].segEnd,
      ),
    );
    _prevText = newText;
    _syncedText = newText;
    _prevSel = _controller.selection;
    _muting = false;
    _notifier.editActive(newText, structural: true);
    // 批量操作只改权重/禁用,理论上不带进新名字;仍统一喂一次,让「压了
    // _onCtrl 的路径都自己喂翻译」成为无例外的规矩,免得日后新增批量项踩坑。
    _feedTranslation(newText);
    Haptics.selection();
    setState(() => _multiRange = (first, last));
  }

  /// 选区区间 → 顶层单元下标集:单元与词条一一对应(一个逗号段一枚),
  /// 两处多选下标同一个空间,批量操作因此能共用同一套函数。
  Set<int> _rangeSel((int, int) r) => {for (var i = r.$1; i <= r.$2; i++) i};

  void _multiWrap(bool up) {
    final r = _multiRange;
    if (r == null) return;
    _applyBatchKeep(
      batchWrapUnits(_controller.text, _foldBodies, _rangeSel(r), up: up),
    );
  }

  void _multiStepMult(bool up) {
    final r = _multiRange;
    if (r == null) return;
    final step = _settings.weightStep;
    final next =
        ((_multiMult + (up ? step : -step)) * 100).roundToDouble() / 100;
    _multiMult = next;
    _applyBatchKeep(
      batchSetMultUnits(_controller.text, _foldBodies, _rangeSel(r), next),
    );
  }

  void _multiClear() {
    final r = _multiRange;
    if (r == null) return;
    _multiMult = 1.0;
    _applyBatchKeep(
      batchClearWeightUnits(_controller.text, _foldBodies, _rangeSel(r)),
    );
  }

  /// 划词批量的「选中整组」:选区扩到整个权重组,经选区监听重进面板。
  /// 先清 `_multiRange` —— 路由只在「新进多选」时重算起步读数,不清的话扩完
  /// 读数还停在上一批,而调组权重得从组倍率起步才对得上。
  void _multiSelectGroup(WeightSpan g, Set<int> _) {
    setState(() => _multiRange = null);
    _controller.selection = TextSelection(
      baseOffset: g.start,
      extentOffset: g.end,
    );
  }

  /// 批量禁用/启用:与多选模式同一条语义(第一枚散标签定目标,折叠跳过)。
  /// 从前按词条区间套 `~`,选区扫过折叠占位符时会把折叠拆散。
  void _multiToggleDisabled() {
    final r = _multiRange;
    if (r == null) return;
    final sel = _rangeSel(r);
    final units = topLevelUnits(_controller.text, _foldBodies);
    final target = _disableTarget(units, sel);
    if (target == null) return;
    _applyBatchKeep(
      setUnitsDisabled(_controller.text, _foldBodies, sel, target),
    );
  }

  void _multiDelete() {
    final r = _multiRange;
    if (r == null) return;
    final (text, cursor) = batchDelete(_controller.text, r.$1, r.$2);
    setState(() => _multiRange = null);
    _applyText(text, cursor);
  }

  /// 「选中整组」:把选区扩到包住当前词条的最外层权重组,
  /// 经选区监听自然进入批量面板(≥2 成员时)。
  void _selectGroupOf(Tok tok) {
    final spans = <WeightSpan>[];
    parseToks(_controller.text, weightSpans: spans);
    WeightSpan? best;
    for (final s in spans) {
      if (s.start > tok.segStart || s.end < tok.segEnd) continue;
      // 恰好等于自身 seg 的是词条自己的权重区间,不算组
      if (s.start == tok.segStart && s.end == tok.segEnd) continue;
      if (best == null || s.end - s.start > best.end - best.start) best = s;
    }
    if (best == null) return;
    _controller.selection = TextSelection(
      baseOffset: best.start,
      extentOffset: best.end,
    );
  }

  /// 关闭批量面板:选区折叠到末端(触发重路由,回到单词条/空 dock)。
  void _multiClose() {
    final sel = _controller.selection;
    setState(() => _multiRange = null);
    if (sel.isValid && !sel.isCollapsed) {
      _controller.selection = TextSelection.collapsed(offset: sel.end);
    }
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
    // 删除即与这枚词条的交互终结。光标落点恰是右邻词条开头,路由会把
    // 面板顺延到下一枚 —— 按过删除的手指还悬在原地,极易误触,压掉。
    if (_panelTok != null) setState(() => _panelTok = null);
    _focus.requestFocus();
  }

  /// SD 权重语法转 NAI(web convertSDToNAI):`(tag:1.2)` → `1.2::tag::`。
  /// 光标留在词首,词条栏随即刷新出转换后的权重。
  void _convertSd() {
    final t = _tokAtCursor();
    if (t == null) return;
    final seg = _controller.text.substring(t.segStart, t.segEnd);
    final ins = sdToNaiSeg(seg);
    if (ins == seg) return;
    _applyText(
      _controller.text.replaceRange(t.segStart, t.segEnd, ins),
      t.segStart,
    );
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
    // 设置改动即时反映到当前会话:关补全清建议、切词条栏重路由、切注音重绘。
    ref.listen<EditorSettings>(
      editorSettingsProvider.select((a) => a.value ?? const EditorSettings()),
      (prev, next) {
        final p = prev ?? const EditorSettings();
        if (p == next) return;
        if (p.enableCompletion && !next.enableCompletion) _clearSuggest();
        if (p.enableTagPanel != next.enableTagPanel) _routeCursor();
        if (p.showTranslation != next.showTranslation) {
          _controller.showTrans = next.showTranslation;
          _refreshAnnotations();
        }
        // 实体建议切换:正在显示的补全就地重查(结果有缓存,秒回)
        if (p.entitySuggest != next.entitySuggest && _query.isNotEmpty) {
          _scheduleQuery();
        }
      },
    );
    final settings =
        ref.watch(editorSettingsProvider).value ?? const EditorSettings();
    _controller.showTrans = settings.showTranslation;
    // 折叠表灌进控制器(着色/热区/药丸判占位符用);registerFold/load 改表
    // 即触发本 build 重灌 + 重绘。
    final foldBodies = ref.watch(editorProvider.select((s) => s.foldBodies));
    _controller.foldBodies = foldBodies;

    return Theme(
      data: editorTheme(context),
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
                  EditorTopBar(
                    charName: _charName,
                    onBack: () => Navigator.of(context).maybePop(),
                    onSettings: _openSettings,
                  ),
                  Expanded(
                    // 排序模式切换成真 chip 流视图;编辑态是注音富文本。
                    // 切正/负时编辑区随方向轻滑 + 淡入(单实例,不复制
                    // TextField——controller/focus 不能同时挂两棵树)
                    child: _sortMode
                        ? SortChipsView(
                            controller: _controller,
                            foldBodies: foldBodies,
                            selection: _sortSel,
                            onSelectionChanged: _setSortSel,
                            onMove: _moveUnits,
                            abnormalThreshold: settings.abnormalThreshold,
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
                                  showTrans: settings.showTranslation,
                                  showWeightWash: settings.showWeightWash,
                                  fontSize: settings.fontSize,
                                  abnormalThreshold: settings.abnormalThreshold,
                                  onFoldTap: _unfoldByName,
                                  hint: '点击输入标签,可输入中文自动触发翻译与联想',
                                ),
                              ),
                            ),
                          ),
                  ),
                  // dock 入场:淡入 + 轻微上滑(高度瞬时占位,不撑盒子,避免橡皮筋)
                  // 离场(关面板/收补全)比入场快:走了就别在路上磨蹭。
                  AnimatedSwitcher(
                    duration: Motion.fast,
                    reverseDuration: Motion.quick,
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

  /// 批量面板(两处多选共用):选中集 → 能力位 → 面板。越界下标(正文刚被
  /// 改短)先滤掉,面板只反映当前正文。
  Widget _batchPanel(
    Key key,
    Set<int> sel,
    double mult, {
    required void Function(WeightSpan g, Set<int> covered) onSelectGroup,
    required void Function(bool up) onWrap,
    required void Function(bool up) onStepMult,
    required VoidCallback onClearWeight,
    required VoidCallback onToggleDisabled,
    required VoidCallback onDelete,
    required VoidCallback onClose,
  }) {
    final units = topLevelUnits(_controller.text, _foldBodies);
    final live = {
      for (final i in sel)
        if (i >= 0 && i < units.length) i,
    };
    var canDisable = false;
    var anyEnabled = false;
    for (final i in live) {
      if (units[i].tok case final t?) {
        // 折叠单元不能禁用(套 ~ 会把折叠拆散),全是折叠时这个键就该灰着
        canDisable = true;
        if (!t.disabled) anyEnabled = true;
      }
    }
    final group = _groupSelOf(units, live);
    return BatchPanel(
      key: key,
      count: live.length,
      mult: mult,
      canWeight: weightRuns(units, live).isNotEmpty,
      canDisable: canDisable,
      anyEnabled: anyEnabled,
      groupMult: group?.$1.mult,
      onSelectGroup: group == null
          ? null
          : () => onSelectGroup(group.$1, group.$2),
      onCopy: () => _copyUnits(live),
      onWrap: onWrap,
      onStepMult: onStepMult,
      onClearWeight: onClearWeight,
      onToggleDisabled: onToggleDisabled,
      onDelete: onDelete,
      onClose: onClose,
    );
  }

  Widget _dock() {
    // key 稳定=同一形态内更新不重播入场动画(如长按连续调权重);切形态才动画
    //
    // 两处多选共用同一张批量面板:多选模式点 chip 攒集合(可跳选),划词多选
    // 扫出连续区间 —— 到了面板都只是「选中了哪些顶层单元」。
    if (_sortMode) {
      return _batchPanel(
        const ValueKey('dock-sort'),
        _sortSel,
        _sortMult,
        // 扩到整组:组盖住的单元全部收进选中(读数随之落到组倍率)
        onSelectGroup: (_, covered) => _setSortSel(covered),
        onWrap: _sortWrap,
        onStepMult: _sortStepMult,
        onClearWeight: _sortClearWeight,
        onToggleDisabled: _sortToggleDisabled,
        onDelete: _sortDelete,
        onClose: () => _setSortSel({}),
      );
    }
    if (_multiRange != null) {
      final r = _multiRange!;
      if (r.$1 < parseToks(_controller.text).length) {
        return _batchPanel(
          const ValueKey('dock-multi'),
          _rangeSel(r),
          _multiMult,
          onSelectGroup: _multiSelectGroup,
          onWrap: _multiWrap,
          onStepMult: _multiStepMult,
          onClearWeight: _multiClear,
          onToggleDisabled: _multiToggleDisabled,
          onDelete: _multiDelete,
          onClose: _multiClose,
        );
      }
    }
    if (_query.isNotEmpty) {
      return CompletionBar(
        key: const ValueKey('dock-completion'),
        query: _query,
        result: _result,
        loading: _loading,
        translating: _translating,
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
        weightStep: _settings.weightStep,
        warning: abnormalWeightOf(
          _controller.text,
          tok,
          threshold: _settings.abnormalThreshold,
        ),
        sdConvert:
            isSdWeightSeg(_controller.text.substring(tok.segStart, tok.segEnd))
            ? _convertSd
            : null,
        onSelectGroup: (tok.groupMult - 1).abs() > 0.0001
            ? () => _selectGroupOf(tok)
            : null,
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
