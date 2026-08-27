import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/stats/key_ledger.dart';

/// 本机账本:聚合口径、时间范围、流水合并、落盘往返、脏档容错。
/// 固定「现在」= 2026-01-15(周四):今日 1-15,本周 1-12(周一)起,本月 1-1 起。
void main() {
  final now = DateTime(2026, 1, 15, 12);

  late Directory root;
  late KeyLedgerStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_ledger');
    store = KeyLedgerStore(root);
  });

  Future<void> teardownDir() async {
    await store.flush();
    await store.idle;
    for (var i = 0; i < 10; i++) {
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  tearDown(teardownDir);

  void seed(KeyLedgerStore s) {
    // 时间正序录入(单笔操作依赖「新在前」的插入序)
    s.recordGen(pts: 9, at: DateTime(2025, 12, 30, 10));
    s.recordGen(pts: 0, at: DateTime(2026, 1, 5, 9));
    s.recordOp('vibe', 2, at: DateTime(2026, 1, 5, 10));
    s.recordGen(pts: 20, at: DateTime(2026, 1, 13, 21));
    s.recordOp('upscale', 7, at: DateTime(2026, 1, 15, 9));
    s.recordGen(pts: 0, at: DateTime(2026, 1, 15, 10));
    s.recordGen(pts: 0, at: DateTime(2026, 1, 15, 11));
    s.recordGen(pts: 12, at: DateTime(2026, 1, 15, 11, 30));
  }

  test('聚合与范围口径', () {
    seed(store);

    final today = store.sumRange('today', now: now);
    expect((today.images, today.free, today.genPts), (3, 2, 12));
    expect((today.vibePts, today.upsPts), (0, 7));

    final week = store.sumRange('week', now: now);
    expect((week.images, week.free, week.genPts), (4, 2, 32));
    expect((week.vibePts, week.upsPts), (0, 7));

    final month = store.sumRange('month', now: now);
    expect((month.images, month.free, month.genPts), (5, 3, 32));
    expect((month.vibePts, month.upsPts), (2, 7));

    expect(store.totalImages, 6);
    expect(store.totalFree, 3);
    expect(store.totalGenPts, 41);
    expect(store.totalPts, 41 + 2 + 7);
  });

  test('趋势序列随范围切换', () {
    seed(store);

    // 本周:周一(1-12)起 7 天,13 日 1 张 / 15 日 3 张;
    // 点数含单笔操作(15 日超分 7 点 + 生成 12 点)
    final week = store.seriesFor('week', now: now);
    expect(week.length, 7);
    expect(week.map((p) => p.images).toList(), [0, 1, 0, 3, 0, 0, 0]);
    expect(week[1].pts, 20);
    expect(week[3].pts, 19);
    expect(week.map((p) => p.label).toList(), [
      '一',
      '二',
      '三',
      '四',
      '五',
      '六',
      '日',
    ]);

    // 本月:1 号至今 15 格,5 日 1 张(含 vibe 2 点)
    final month = store.seriesFor('month', now: now);
    expect(month.length, 15);
    expect(month[4].images, 1);
    expect(month[4].pts, 2);
    expect(month[12].images, 1);

    // 今日:24 小时,10/11 点各 1 张免费、11 点另有 12 点的计费张,9 点超分 7 点
    final today = store.seriesFor('today', now: now);
    expect(today.length, 24);
    expect(today[9].images, 0);
    expect(today[9].pts, 7);
    expect(today[10].images, 1);
    expect(today[11].images, 2);
    expect(today[11].pts, 12);
  });

  test('逐笔生成明细按天可查并随落盘往返', () async {
    store.recordGen(
      pts: 0,
      at: DateTime(2026, 1, 15, 10),
      width: 832,
      height: 1216,
      steps: 28,
      model: 'NAI 4.5 Full',
    );
    store.recordGen(
      pts: 12,
      at: DateTime(2026, 1, 15, 11),
      width: 1024,
      height: 1536,
      steps: 28,
      model: 'NAI 4.5 Full',
      inpaint: true,
    );
    store.recordGen(pts: 0, at: DateTime(2026, 1, 14, 9)); // 无参数:只进聚合
    store.recordOp('vibe', 2, at: DateTime(2026, 1, 15, 12));

    final day = store.gensForDay('2026-01-15');
    expect(day.length, 2);
    expect(day.first.pts, 12); // 新在前
    expect(day.first.inpaint, isTrue);
    expect(day.last.width, 832);
    expect(store.gensForDay('2026-01-14'), isEmpty); // 无参数那笔不留明细
    expect(store.days['2026-01-14']!.images, 1); // 但聚合照记
    expect(store.opsForDay('2026-01-15').length, 1);

    await store.flush();
    await store.idle;
    final again = KeyLedgerStore(root);
    await again.load();
    final back = again.gensForDay('2026-01-15');
    expect(back.length, 2);
    expect(back.first.model, 'NAI 4.5 Full');
    expect(back.first.steps, 28);
    expect(back.last.height, 1216);
  });

  test('跨天后小时桶清零', () {
    store.recordGen(pts: 5, at: DateTime(2026, 1, 14, 20));
    expect(store.hourImages[20], 1);
    store.recordGen(pts: 0, at: DateTime(2026, 1, 15, 8));
    expect(store.hourDay, '2026-01-15');
    expect(store.hourImages[20], 0); // 昨天的桶已清
    expect(store.hourImages[8], 1);
    // 按天聚合不受影响
    expect(store.days['2026-01-14']!.images, 1);
  });

  test('流水合并按时间倒序', () {
    seed(store);
    final rows = store.recentRows(maxDays: 14, now: now);
    // 日行 15/13/5 + 单笔 超分(15日09:00)/vibe(5日10:00)
    expect(rows.length, 5);
    expect(rows[0].gen, isNotNull); // 今天日行(此刻)
    expect(rows[0].day, '2026-01-15');
    expect(rows[1].op?.type, 'upscale'); // 今天 09:00
    expect(rows[2].day, '2026-01-13');
    expect(rows[3].day, '2026-01-05'); // 5 日 23:59 的日行
    expect(rows[4].op?.type, 'vibe'); // 5 日 10:00
  });

  test('落盘往返', () async {
    seed(store);
    await store.flush();
    await store.idle;

    final again = KeyLedgerStore(root);
    await again.load();
    final month = again.sumRange('month', now: now);
    expect((month.images, month.free, month.genPts), (5, 3, 32));
    expect(again.totalPts, 50);
    expect(again.ops.length, 2);
    expect(again.ops.first.type, 'upscale'); // 新在前的持久化顺序
  });

  test('V5 单列:张数含免费档,点数只记真扣的那些', () async {
    // 免费尺寸的 V5(额度还没见底)→ 计张不计点
    store.recordGen(pts: 0, at: DateTime(2026, 1, 15, 9), v5: true);
    // 额度见底后同样尺寸转扣点 / 或超尺寸 → 两个都计
    store.recordGen(pts: 30, at: DateTime(2026, 1, 15, 10), v5: true);
    // 4.5 那些不进 V5 两项,但照常进总数
    store.recordGen(pts: 20, at: DateTime(2026, 1, 15, 11));

    final today = store.sumRange('today', now: now);
    expect((today.images, today.genPts), (3, 50));
    expect((today.v5, today.v5Pts), (2, 30));
    expect((store.totalV5, store.totalV5Pts), (2, 30));

    // 落盘往返:两项跟着 days / totals 一起持久化
    await store.flush();
    await store.idle;
    final again = KeyLedgerStore(root);
    await again.load();
    final back = again.sumRange('today', now: now);
    expect((back.v5, back.v5Pts), (2, 30));
    expect((again.totalV5, again.totalV5Pts), (2, 30));
  });

  test('老档没有 V5 两项:读成 0,不炸也不误报', () async {
    final f = File(
      '${root.path}${Platform.pathSeparator}stats'
      '${Platform.pathSeparator}key_ledger.json',
    );
    f.parent.createSync(recursive: true);
    // V5 之前那版的格式:days 三项、totals 五项
    f.writeAsStringSync(
      '{"v":1,"days":{"2026-01-15":[4,2,12]},'
      '"totals":[4,2,12,0,0],"ops":[],"gens":[]}',
    );
    final s = KeyLedgerStore(root);
    await s.load();
    final today = s.sumRange('today', now: now);
    expect((today.images, today.genPts), (4, 12));
    expect((today.v5, today.v5Pts), (0, 0));
    expect((s.totalV5, s.totalV5Pts), (0, 0));
  });

  test('脏档按空账本降级', () async {
    final f = File(
      '${root.path}${Platform.pathSeparator}stats'
      '${Platform.pathSeparator}key_ledger.json',
    );
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('{broken json!!');
    final s = KeyLedgerStore(root);
    await s.load();
    expect(s.totalImages, 0);
    expect(s.days, isEmpty);
    s.recordGen(pts: 0); // 仍可正常记新账
    expect(s.totalImages, 1);
    await s.flush();
    await s.idle;
  });
}
