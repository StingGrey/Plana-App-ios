import 'package:flutter/material.dart';

/// 会话内滚动位置记忆。
///
/// 只活在内存里,**不落盘**:冷启动回到顶部是预期行为,不算丢记忆。
/// 解决的是「离开页面再回来被弹回顶部」——包括三种离开方式:
/// - shell 的 PageView 划走(无 keepAlive 的页会被销毁);
/// - push 新路由再弹回(路由自带的 PageStorage 桶随路由实例走,重进即新桶);
/// - 同一页内换子作用域(如灵感页换分类),此时靠 key 分账。
///
/// key 约定带上子作用域,如 `inspiration.character.mine`。
class ScrollMemory {
  ScrollMemory._();

  static final _offsets = <String, double>{};

  static double? read(String key) => _offsets[key];

  static void write(String key, double value) => _offsets[key] = value;

  static void forget(String key) => _offsets.remove(key);
}

/// 按 [memoKey] 落位、并持续记账的滚动控制器。
///
/// 记账有个前提:**内容确实可滚动**。加载态 / 空列表的 maxScrollExtent 是 0,
/// 这时候记账会把之前存的位置冲成 0,回来就白记了——所以这类帧一律跳过。
class MemoScrollController extends ScrollController {
  MemoScrollController(this.memoKey)
    : super(initialScrollOffset: ScrollMemory.read(memoKey) ?? 0) {
    addListener(_save);
  }

  final String memoKey;

  void _save() {
    if (!hasClients || positions.length != 1) return;
    final p = position;
    if (!p.hasContentDimensions || p.maxScrollExtent <= 0) return;
    ScrollMemory.write(memoKey, p.pixels);
  }

  @override
  void dispose() {
    removeListener(_save);
    super.dispose();
  }
}

/// 给**无状态页**挂记忆型滚动控制器:页面本身不用改成 Stateful。
/// [memoKey] 视为固定值(换 key 请换 widget key,别原地改)。
class ScrollMemo extends StatefulWidget {
  const ScrollMemo({super.key, required this.memoKey, required this.builder});

  final String memoKey;

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<ScrollMemo> createState() => _ScrollMemoState();
}

class _ScrollMemoState extends State<ScrollMemo> {
  late final MemoScrollController _c = MemoScrollController(widget.memoKey);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _c);
}
