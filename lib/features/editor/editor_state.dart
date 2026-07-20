import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../generate/generate_state.dart';
import 'editor_models.dart';

final editorProvider = NotifierProvider<EditorNotifier, EditorState>(
  EditorNotifier.new,
);

/// 光标驱动定稿:字符串就是真相,正/负各一条(含原样权重语法)。
class EditorState {
  const EditorState({
    this.positiveText = '',
    this.negativeText = '',
    this.activePositive = true,
    this.canUndo = false,
  });

  final String positiveText;
  final String negativeText;
  final bool activePositive;
  final bool canUndo;

  String get activeText => activePositive ? positiveText : negativeText;
  int get activeTokens => estimateTokens(outputOf(activeText));

  EditorState copyWith({
    String? positiveText,
    String? negativeText,
    bool? activePositive,
    bool? canUndo,
  }) => EditorState(
    positiveText: positiveText ?? this.positiveText,
    negativeText: negativeText ?? this.negativeText,
    activePositive: activePositive ?? this.activePositive,
    canUndo: canUndo ?? this.canUndo,
  );
}

typedef _Snap = (String pos, String neg);

class EditorNotifier extends Notifier<EditorState> {
  final List<_Snap> _history = [];
  static const _maxHistory = 60;
  int _lastPushMs = 0;

  /// 本次会话的编辑目标:null = 创作页主提示词,否则 = 该 id 的角色提示词。
  /// 进页面时由 [load] 钉死,中途不变。用 id 不用名字——角色自动编号
  /// (「角色 N」)在删掉中间一个再新增时会重名,名字不是稳定句柄。
  String? _charId;

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
  }) {
    _writeBack?.cancel(); // 新会话,作废上一会话可能挂着的回写
    _history.clear();
    _lastPushMs = 0;
    _charId = charId;
    state = EditorState(
      positiveText: positive,
      negativeText: negative,
      activePositive: startPositive,
      canUndo: false,
    );
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
    final gen = ref.read(generateProvider.notifier);
    final id = _charId;
    if (id == null) {
      gen.setPrompts(positive: outputPositive(), negative: outputNegative());
      return;
    }
    final pos = outputPositive();
    final neg = outputNegative();
    // updateCharacter 没有 setPrompts 那样的同值短路,这里自己挡一道:
    // 防抖回写高频触发,内容没变不该惊动创作页重建与落盘。
    for (final c in ref.read(generateProvider).characters) {
      if (c.id != id) continue;
      if (c.positive == pos && c.negative == neg) return;
      break;
    }
    gen.updateCharacter(id, positive: pos, negative: neg);
  }

  /// 写入当前段。structural=true(删/插/改权重等)必入撤销栈,打字按 700ms 合并。
  void editActive(String text, {bool structural = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (structural || now - _lastPushMs > 700) {
      _history.add((state.positiveText, state.negativeText));
      if (_history.length > _maxHistory) _history.removeAt(0);
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
    if (_history.isEmpty) return;
    final s = _history.removeLast();
    _lastPushMs = 0;
    state = state.copyWith(
      positiveText: s.$1,
      negativeText: s.$2,
      canUndo: _history.isNotEmpty,
    );
    _scheduleWriteBack();
  }

  String outputPositive() => outputOf(state.positiveText);
  String outputNegative() => outputOf(state.negativeText);
}
