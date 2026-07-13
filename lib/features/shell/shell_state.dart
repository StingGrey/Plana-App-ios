import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前底部 tab 索引(0 创作 / 1 图库 / 2 我的)。
/// 独立成 Provider,好让「生成完成跳图库」「缺 token 跳我的」等跨页切换。
final shellIndexProvider =
    NotifierProvider<ShellIndexNotifier, int>(ShellIndexNotifier.new);

class ShellIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int i) => state = i;
}
