import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  EditorState build() => const EditorState();

  void load({
    required String positive,
    required String negative,
    required bool startPositive,
  }) {
    _history.clear();
    _lastPushMs = 0;
    state = EditorState(
      positiveText: positive,
      negativeText: negative,
      activePositive: startPositive,
      canUndo: false,
    );
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
  }

  String outputPositive() => outputOf(state.positiveText);
  String outputNegative() => outputOf(state.negativeText);
}
