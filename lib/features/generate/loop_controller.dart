import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/live_progress/live_progress.dart';
import '../shell/shell_state.dart';
import 'generate_state.dart';
import 'generation_controller.dart';

/// 循环生成状态。batch 为当前第几张(1-based);total 0 表示无限;
/// stopping 表示已请求停止,本张跑完后不再续。
class LoopStatus {
  const LoopStatus({
    this.active = false,
    this.batch = 0,
    this.total = 0,
    this.stopping = false,
  });

  final bool active;
  final int batch;
  final int total;
  final bool stopping;

  LoopStatus copyWith({bool? active, int? batch, int? total, bool? stopping}) =>
      LoopStatus(
        active: active ?? this.active,
        batch: batch ?? this.batch,
        total: total ?? this.total,
        stopping: stopping ?? this.stopping,
      );
}

final loopStatusProvider = NotifierProvider<LoopNotifier, LoopStatus>(
  LoopNotifier.new,
);

/// 循环控制器:顺序连跑 N 张(对齐 web:每轮重读当前编辑器参数、seed 留空
/// 则每轮随机、停止让当前张跑完)。与 web 不同:单张失败即停(移动端挂机
/// 连续失败无意义),错误由单张生成流程弹出。
class LoopNotifier extends Notifier<LoopStatus> {
  @override
  LoopStatus build() => const LoopStatus();

  bool get _appForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<void> start() async {
    if (state.active || ref.read(generationProvider).busy) return;
    final total = ref.read(generateProvider).params.loop.count; // 开跑时锁档位
    state = LoopStatus(active: true, total: total);
    // 只在开跑时切一次图库;之后每张不再强拉(generate 里按 _inLoop 跳过)
    ref.read(shellIndexProvider.notifier).select(1);

    var done = 0; // 成功张数
    var ok = true;
    while (!state.stopping && (total == 0 || done < total)) {
      state = state.copyWith(batch: done + 1);
      ok = await ref.read(generationProvider.notifier).generate();
      if (!ok) break;
      done++;
    }
    state = const LoopStatus();

    // 循环期间单张不撤/不留通知(见 generation_controller._inLoop),
    // 统一在此收尾:前台静默撤;后台留一条汇总,可点回应用。
    if (_appForeground) {
      await LiveProgress.instance.stop();
    } else {
      await LiveProgress.instance.finish(
        text: ok
            ? '循环完成 · 共 $done 张'
            : (done > 0 ? '循环中止 · 已出 $done 张' : '生成失败'),
      );
    }
  }

  /// 请求停止:当前张跑完后不再续(不打断进行中的生成)。
  void stop() {
    if (state.active) state = state.copyWith(stopping: true);
  }
}
