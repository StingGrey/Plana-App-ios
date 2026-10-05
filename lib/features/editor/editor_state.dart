import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../generate/generate_state.dart';
import '../generate/canvas_state.dart';
import '../generate/models.dart' show PromptSection;
import '../generate/prompt_sections.dart' show normalizeSections;
import 'editor_models.dart';

final editorProvider = NotifierProvider<EditorNotifier, EditorState>(
  EditorNotifier.new,
);

/// 光标驱动定稿:字符串就是真相,正/负各一条(含原样权重语法)。
/// 折叠体不在正文里(正文只有 `<#名字>` 占位符),存 [foldBodies];
/// 只增不删且跨会话留存于撤销档(解散/删除只动正文,表项留着给撤销兜底),
/// 定稿与草稿都经 [expandFolds] 拼回完整语法后再算。
/// 撤销栈按编辑目标跨会话长效(见 [_UndoArchive]),退出编辑器不重置。
class EditorState {
  const EditorState({
    this.positiveText = '',
    this.negativeText = '',
    this.activePositive = true,
    this.canUndo = false,
    this.foldBodies = const {},
  });

  final String positiveText;
  final String negativeText;
  final bool activePositive;
  final bool canUndo;

  /// 折叠表:占位符名字 → 折叠体(正/负两侧共用,载入时已跨侧去重)。
  final Map<String, String> foldBodies;

  String get activeText => activePositive ? positiveText : negativeText;

  /// 当前段定稿(占位符展开 + 剔除编辑期语法)。token 读数用。
  String get activeOutput => outputOf(expandFolds(activeText, foldBodies));

  EditorState copyWith({
    String? positiveText,
    String? negativeText,
    bool? activePositive,
    bool? canUndo,
    Map<String, String>? foldBodies,
  }) => EditorState(
    positiveText: positiveText ?? this.positiveText,
    negativeText: negativeText ?? this.negativeText,
    activePositive: activePositive ?? this.activePositive,
    canUndo: canUndo ?? this.canUndo,
    foldBodies: foldBodies ?? this.foldBodies,
  );
}

/// 撤销档的一步:撤回后的正 / 负文本。第三项非空 = 这一步是「提取为新分区」,
/// 记着那时建出的一格:撤回时一并拿掉,不然同一批词原处、新格各一份。
typedef _Snap = (String pos, String neg, PromptSection? extracted);

/// 单个编辑目标(主提示词/某角色)的撤销档。**进程级长效**:退出编辑器
/// 不清空,重进接着撤,只在进程结束或角色被删时消亡。折叠表一并留存且
/// 只增不删 —— 历史快照里的占位符要靠它才解析得回(会话内「表只增不删」
/// 原则的跨会话延伸;表悬空会让占位符漏成 `#名字` 字面量进提示词)。
class _UndoArchive {
  final List<_Snap> snaps = [];
  Map<String, String> folds = const {};
}

class EditorNotifier extends Notifier<EditorState> {
  /// 画布 + 编辑目标共同构成撤销档 key。
  final Map<String, _UndoArchive> _archives = {};
  static const _maxHistory = 60;
  int _lastPushMs = 0;

  _UndoArchive get _arc =>
      _archives.putIfAbsent('$_canvasId/$_targetKey', _UndoArchive.new);

  /// 撤销档里的目标名:主提示词 '',角色是它的 id,分区加 `s:` 前缀(两边的
  /// id 出自同一个发号器,前缀只是让人一眼分得清)。
  String get _targetKey =>
      _charId ?? (_sectionId == null ? '' : 's:$_sectionId');

  /// 本次会话的编辑目标:都为 null = 创作页主提示词;[_charId] = 该角色;
  /// [_sectionId] = 主提示词的该分区。进页面时由 [load] 钉死,中途不变。
  /// 用 id 不用名字——角色自动编号(「角色 N」)在删掉中间一个再新增时
  /// 会重名,名字不是稳定句柄。
  String? _charId;
  String? _sectionId;
  String? _canvasId;

  /// 编辑中实时回写创作页的防抖(编辑器内容不再只活在内存:
  /// 回写进 generateProvider 后由工作台持久化链自动落盘,
  /// 中途被杀最多丢一个防抖窗口的字)。
  Timer? _writeBack;

  @override
  EditorState build() => const EditorState();

  void load({
    required String positive,
    required String negative,
    required bool startPositive,
    String? charId,
    String? sectionId,
  }) {
    _writeBack?.cancel(); // 新会话,作废上一会话可能挂着的回写
    _lastPushMs = 0;
    _charId = charId;
    _sectionId = charId == null ? sectionId : null;
    _canvasId = ref.read(canvasWorkspaceProvider).activeId;
    // 角色 / 分区已删,其撤销档随之作废(主档 '' 恒保留)
    final gen = ref.read(generateProvider);
    final live = <String>{
      '',
      for (final c in gen.characters) c.id,
      for (final s in gen.sections) 's:${s.id}',
    };
    _archives.removeWhere(
      (k, _) =>
          k.startsWith('$_canvasId/') &&
          !live.contains(k.substring('$_canvasId/'.length)),
    );
    final arc = _arc;
    // 草稿(完整折叠语法)→ 正文占位符 + 折叠表。负面侧避开正面已占的
    // 名字,两侧共同避开撤销档已占的名字(同名同体复用,不同体加序号 ——
    // 免得本次载入的折叠顶掉历史快照还指望着的同名旧折叠体)。
    final (posText, posBodies) = collapseFolds(positive, seed: arc.folds);
    final (negText, negBodies) = collapseFolds(
      negative,
      seed: {...arc.folds, ...posBodies},
    );
    arc.folds = {...arc.folds, ...posBodies, ...negBodies};
    state = EditorState(
      positiveText: posText,
      negativeText: negText,
      activePositive: startPositive,
      canUndo: arc.snaps.isNotEmpty,
      foldBodies: arc.folds,
    );
  }

  /// 注册一个折叠体(补全插入画师串 / OC 标签组时),返回占位符该用的名字
  /// (重名且内容不同时自动加序号)。表只增不删——撤销回带占位符的旧文本时
  /// 仍能解析。
  String registerFold(String name, String body) {
    final n = uniqueFoldName(name, body, state.foldBodies);
    final next = {...state.foldBodies, n: body};
    _arc.folds = next; // 撤销档同步留存:快照回带占位符时仍解析得回
    state = state.copyWith(foldBodies: next);
    return n;
  }

  void _scheduleWriteBack() {
    _writeBack?.cancel();
    _writeBack = Timer(const Duration(milliseconds: 400), flushWriteBack);
  }

  /// 立即把当前定稿回写(防抖到点/离开编辑器/退后台共用)。
  /// 目标由 [load] 钉死的 [_charId] 决定:角色会话绝不写主提示词
  /// ——从前这里写死了 setPrompts,点角色卡进来编辑会静默覆盖主提示词。
  void flushWriteBack() {
    _writeBack?.cancel();
    _writeBack = null;
    final canvasId = _canvasId;
    if (canvasId == null) return;
    final id = _charId;
    final sectionId = _sectionId;
    // 草稿 = 占位符展开回完整折叠语法(下次载入原样收回);定稿再剔编辑期语法
    final posDraft = expandFolds(state.positiveText, state.foldBodies);
    final negDraft = expandFolds(state.negativeText, state.foldBodies);
    final pos = outputOf(posDraft);
    final neg = outputOf(negDraft);
    final posRaw = draftOf(posDraft, pos);
    final negRaw = draftOf(negDraft, neg);
    // 按进编辑器时的画布回写:编辑中途切了画布,写的也还是原来那张
    ref.read(canvasWorkspaceProvider.notifier).updatePrompts(canvasId, (p) {
      if (sectionId != null) {
        // 这一格已经删了就不写(同角色会话:绝不改写到别处)
        final cur = p.sections.where((x) => x.id == sectionId).firstOrNull;
        if (cur == null ||
            (cur.positive == pos &&
                cur.negative == neg &&
                cur.positiveRaw == posRaw &&
                cur.negativeRaw == negRaw)) {
          return p;
        }
        return p.copyWith(
          sections: [
            for (final s in p.sections)
              if (s.id == sectionId)
                s.copyWith(
                  positive: pos,
                  negative: neg,
                  positiveRaw: posRaw,
                  negativeRaw: negRaw,
                )
              else
                s,
          ],
        );
      }
      if (id == null) {
        if (p.prompt == pos &&
            p.negativePrompt == neg &&
            p.promptRaw == posRaw &&
            p.negativePromptRaw == negRaw) {
          return p;
        }
        return p.copyWith(
          prompt: pos,
          negativePrompt: neg,
          promptRaw: posRaw,
          negativePromptRaw: negRaw,
        );
      }
      final c = p.characters.where((c) => c.id == id).firstOrNull;
      if (c == null ||
          (c.positive == pos &&
              c.negative == neg &&
              c.positiveRaw == posRaw &&
              c.negativeRaw == negRaw)) {
        return p;
      }
      return p.copyWith(
        characters: [
          for (final c in p.characters)
            if (c.id == id)
              c.copyWith(
                positive: pos,
                negative: neg,
                positiveRaw: posRaw,
                negativeRaw: negRaw,
              )
            else
              c,
        ],
      );
    });
  }

  void flushPendingWriteBack() {
    if (_writeBack?.isActive ?? false) flushWriteBack();
  }

  /// 写入当前段。structural=true(删/插/改权重等)必入撤销栈,打字按 700ms 合并。
  /// [extracted] = 这一步把所选提取成了这一格(见 [_Snap])。
  void editActive(
    String text, {
    bool structural = false,
    PromptSection? extracted,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (structural || extracted != null || now - _lastPushMs > 700) {
      final snaps = _arc.snaps;
      snaps.add((state.positiveText, state.negativeText, extracted));
      if (snaps.length > _maxHistory) snaps.removeAt(0);
      _lastPushMs = now;
    }
    state = state.activePositive
        ? state.copyWith(positiveText: text, canUndo: true)
        : state.copyWith(negativeText: text, canUndo: true);
    _scheduleWriteBack();
  }

  void setActivePositive(bool v) {
    if (v == state.activePositive) return;
    state = state.copyWith(activePositive: v);
  }

  void undo() {
    final snaps = _arc.snaps;
    if (snaps.isEmpty) return;
    final s = snaps.removeLast();
    _lastPushMs = 0;
    state = state.copyWith(
      positiveText: s.$1,
      negativeText: s.$2,
      canUndo: snaps.isNotEmpty,
    );
    if (s.$3 case final extracted?) _dropExtracted(extracted);
    _scheduleWriteBack();
  }

  /// 撤回一次「提取为新分区」:那一格还在、词也没改过,就从它所在的画布
  /// 拿掉;改过的留着 —— 那是之后另写的东西,撤销不该替人扔掉。
  void _dropExtracted(PromptSection section) {
    final canvasId = _canvasId;
    if (canvasId == null) return;
    ref.read(canvasWorkspaceProvider.notifier).updatePrompts(canvasId, (p) {
      final cur = p.sections.where((x) => x.id == section.id).firstOrNull;
      if (cur == null ||
          cur.positive != section.positive ||
          cur.negative != section.negative ||
          cur.positiveRaw != section.positiveRaw ||
          cur.negativeRaw != section.negativeRaw) {
        return p;
      }
      return p.copyWith(
        sections: normalizeSections([
          for (final x in p.sections)
            if (x.id != section.id) x,
        ]),
      );
    });
  }

  String outputPositive() =>
      outputOf(expandFolds(state.positiveText, state.foldBodies));
  String outputNegative() =>
      outputOf(expandFolds(state.negativeText, state.foldBodies));
}
