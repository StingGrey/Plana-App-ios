import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 底部 tab 索引常量(跨页跳转统一引用,别再写裸数字)。
const kTabCreate = 0;
const kTabGallery = 1;
const kTabInspiration = 2;
const kTabProfile = 3;

/// 当前底部 tab 索引。
/// 独立成 Provider,好让「生成完成跳图库」「缺 token 跳我的」等跨页切换。
final shellIndexProvider = NotifierProvider<ShellIndexNotifier, int>(
  ShellIndexNotifier.new,
);

/// 当前是否启用横屏平板工作台。生成控制器据此决定是否还需要自动跳图库:
/// 平板首页已经常驻画布,再跳走反而会把左侧设置从眼前撤掉。
final tabletWorkspaceProvider = NotifierProvider<TabletWorkspaceNotifier, bool>(
  TabletWorkspaceNotifier.new,
);

class ShellIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int i) => state = i;
}

class TabletWorkspaceNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) {
    if (state != value) state = value;
  }
}
