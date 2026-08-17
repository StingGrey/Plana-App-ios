// 进度条**一根条按阶段各走各的**(与 web 同一套):
//   拉 LoRA（有百分比）→ 归零 → 加载模型（没有百分比,走不确定）→ 归零 → 采样
// 旁边的文案说明当前在哪一段。
//
// 这里钉两件事:
//   ① 采样一开始,准备阶段那份百分比就得作废,不能和步数抢着画;
//   ② 「在不在采样」得单独判,不能拿「进度条有没有值」代替 —— 准备阶段现在
//      也画得出条来,拿有没有值判会在那几分钟里把读数显示成「0/0」。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';

GenJob _job({int step = 0, int total = 0, int prepPct = -1}) => GenJob(
  id: 'j',
  kind: GenJobKind.normal,
  stage: GenJobStage.running,
  width: 832,
  height: 1216,
  seq: 1,
  step: step,
  total: total,
  prepPct: prepPct,
);

void main() {
  test('刚提交:什么都没有 → 不确定进度', () {
    final j = _job();
    expect(j.progress, isNull);
    expect(j.sampling, isFalse);
  });

  test('拉 LoRA:借它的百分比画条', () {
    expect(_job(prepPct: 42).progress, closeTo(0.42, 1e-9));
    expect(_job(prepPct: 0).progress, 0.0, reason: '0% 也是有效读数,不是"没有"');
    expect(_job(prepPct: 100).progress, 1.0);
  });

  // 换阶段服务端就不再下发 phase_pct,调用方把它写回 -1;
  // 不清的话「加载模型」会顶着上一段留下的 100% 不动,比没有条更像卡死
  test('加载模型:百分比清成 -1 → 回到不确定进度', () {
    expect(_job(prepPct: -1).progress, isNull);
  });

  test('采样开始:走步数,准备阶段那份已作废', () {
    final j = _job(step: 9, total: 36);
    expect(j.sampling, isTrue);
    expect(j.progress, closeTo(0.25, 1e-9));
  });

  // 万一 prepPct 没被清干净,步数也必须压过它 —— 两份读数抢一根条时以采样为准
  test('步数压过残留的准备百分比', () {
    expect(_job(step: 9, total: 36, prepPct: 100).progress, closeTo(0.25, 1e-9));
  });

  // anima 的重绘放大是 hires 二段,第二段 step 从 1 重新开始。
  // 条跟着回退是**预期行为**(拉完归零、采样再从头走一遍同理)
  test('重绘二段从头走:条跟着回退,不是 bug', () {
    expect(_job(step: 28, total: 28).progress, 1.0);
    expect(_job(step: 1, total: 28).progress, closeTo(1 / 28, 1e-9));
  });

  group('sampling 与「条有没有值」不是一回事', () {
    test('准备阶段有条但不在采样', () {
      final j = _job(prepPct: 42);
      expect(j.progress, isNotNull);
      expect(j.sampling, isFalse, reason: '按有值判会把读数显示成 0/0');
    });

    test('收尾阶段(跑满)仍算采样过 —— 该显示的是文案不是 36/36', () {
      final j = _job(step: 36, total: 36);
      expect(j.sampling, isTrue);
      expect(j.step >= j.total, isTrue);
    });
  });
}
