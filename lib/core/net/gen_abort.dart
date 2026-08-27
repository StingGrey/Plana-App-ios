/// 生成中止令牌(对齐 web 前端的 AbortController)。
///
/// [abort] 触发所有已注册的钩子——直连生成关掉 HttpClient 连接、bot 生成停止
/// 等待任务——各生成链路据此立即收手。生成控制器据 [aborted] 把中止和真正的
/// 失败区分开:中止就静默回到空闲态,不弹错误。
class GenAbort {
  bool _aborted = false;
  final _hooks = <void Function()>[];

  bool get aborted => _aborted;

  /// 注册中止钩子;若已中止则立即执行(晚注册也能立刻收手)。
  void whenAbort(void Function() hook) {
    if (_aborted) {
      hook();
      return;
    }
    _hooks.add(hook);
  }

  void abort() {
    if (_aborted) return;
    _aborted = true;
    final hooks = List.of(_hooks);
    _hooks.clear();
    for (final h in hooks) {
      try {
        h();
      } catch (_) {}
    }
  }
}
