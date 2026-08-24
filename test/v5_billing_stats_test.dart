import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/generate/generation_controller.dart'
    show isNai5QuotaBlock;

/// 服务端 2026-08-23 那批计费/统计改版在 app 侧的解析口径。
///
/// 这些字段全是**加法式**下发的:老服务端不带,新服务端才有。所以每条都要
/// 确认「缺省不炸、缺省不误导」—— 缺省兜错方向的话,界面会平静地显示一个
/// 错的账单,没人会发现。
void main() {
  group('统计:V5 单列', () {
    test('三个数照常解析,缺省为 0(老服务端)', () {
      final s = UsageStats.fromJson(const {
        'image_calls': 500,
        'points_spent': 1200,
        'v5_calls': 88,
        'v5_points': 300,
        'v5_users': 7,
      });
      expect(s.v5Calls, 88);
      expect(s.v5Points, 300);
      expect(s.v5Users, 7);
      expect(UsageStats.fromJson(const {'image_calls': 5}).v5Calls, 0);
    });
  });

  group('账单:两条免费线', () {
    BillingReport r(Map<String, dynamic> j) => BillingReport.fromJson(j);

    test('v5_free 从 tiers 里取,也认平铺的 v5_free_threshold', () {
      expect(
        r(const {
          'tiers': {'free': 200, 'v5_free': 10, 't1': 0, 't2': 0},
        }).v5FreeThreshold,
        10,
      );
      expect(r(const {'v5_free_threshold': 10}).v5FreeThreshold, 10);
    });

    test('免费档区间要把两条线都写出来 —— 只写 ≤200 的话超了 V5 容差的人看不懂', () {
      final rep = r(const {
        'tiers': {'free': 200, 'v5_free': 10, 't1': 0, 't2': 0},
      });
      expect(rep.rangeOf('免费'), contains('200'));
      expect(rep.rangeOf('免费'), contains('V5'));
      // 老服务端没有第二条线时退回原来那句,不显示一个空的「V5≤0」
      final old = r(const {
        'tiers': {'free': 200, 't1': 0, 't2': 0},
      });
      expect(old.rangeOf('免费'), '≤200 张');
    });

    test('本人行拆出 V5 与自建后端张数;image_calls 只含 NAI', () {
      final me = BillingParty.fromJson(const {
        'image_calls': 120,
        'v5_calls': 30,
        'local_calls': 45,
        'anlas_used': 60,
        'total_fee': 12.0,
      });
      expect(me.imageCalls, 120); // 分摊基数,不含 anima/krea
      expect(me.v5Calls, 30);
      expect(me.localCalls, 45);
    });
  });

  group('账单:生效日之前的周期', () {
    test('before_start_from 透传,并带上生效日', () {
      final rep = BillingReport.fromJson(const {
        'before_start_from': true,
        'billing_start_from': '2026-08-23',
        'billing_month': '07/23 - 08/23',
        'payment_status': 'free',
      });
      expect(rep.beforeStartFrom, isTrue);
      expect(rep.billingStartFrom, '2026-08-23');
    });

    test('缺省为 false —— 兜成 true 会让正常账单整块消失', () {
      expect(BillingReport.fromJson(const {}).beforeStartFrom, isFalse);
    });
  });

  group('结算日从周期标签里取', () {
    int day(String label) =>
        BillingReport.fromJson({'billing_month': label}).cycleDay;

    test('取收尾那个日期的日 —— 分界日改过一次(27 → 23),不该再写死', () {
      expect(day('07/23 - 08/23'), 23);
      expect(day('06/27 - 07/27'), 27);
    });

    test('解析不出回落到 23(当前配置),不抛也不显示 0', () {
      expect(day(''), 23);
      expect(day('本期'), 23);
    });
  });

  group('算力账单:分期', () {
    test('结过账:口径变成本期,带上结算点与上期快照', () {
      final b = GpuBills.fromJson(const {
        'ok': true,
        'items': [],
        'total_cost': 3.5,
        'period': {'since': '2026-08-23T10:56:00', 'label': '8/23 10:56 结算后'},
        'last_period': {
          'label': '7/25 09:30 - 8/23 10:56',
          'cost': 12.34,
          'rental': {'cost': 10.0, 'count': 3, 'hours': 2.5, 'jobs': 40},
          'video': {'cost': 2.34, 'count': 2, 'seconds': 12},
        },
      });
      expect(b.settled, isTrue);
      expect(b.periodLabel, '8/23 10:56 结算后');
      expect(b.lastPeriod!.cost, 12.34);
      expect(b.lastPeriod!.rentalCount, 3);
      expect(b.lastPeriod!.videoSeconds, 12);
    });

    test('没结过账 / 老服务端:口径仍是全部历史,没有上期卡', () {
      final b = GpuBills.fromJson(const {'ok': true, 'total_cost': 3.5});
      expect(b.settled, isFalse);
      expect(b.lastPeriod, isNull);
      // since 显式为 null 也算没结过
      expect(
        GpuBills.fromJson(const {
          'ok': true,
          'period': {'since': null, 'label': ''},
        }).settled,
        isFalse,
      );
    });
  });

  group('某日明细', () {
    test('逐笔记录读服务端给的 is_v5,不在客户端再解析一遍模型名', () {
      expect(
        PointRecord.fromJson(const {
          'timestamp': '2026-08-23T19:23:00',
          'points': 30,
          'reason': 'web生图(生图832x1216_29步=30)',
          'model': 'nai-diffusion-5-full',
          'is_v5': true,
        }).isV5,
        isTrue,
      );
      // 老记录没有这个字段 —— 那时 V5 还没上线,缺省 false 是对的
      expect(
        PointRecord.fromJson(const {'points': 20, 'reason': ''}).isV5,
        isFalse,
      );
    });
  });

  group('额度类拒绝的识别', () {
    test('服务端那三条原文都认得出', () {
      expect(isNai5QuotaBlock('共享账号的 NAI5 免费额度已用完,为避免消耗点数已暂停出图,请稍后重试'), isTrue);
      expect(isNai5QuotaBlock('NAI5 出图额度用完啦,正在回充中,稍后再试(当前 3/200)'), isTrue);
      expect(
        isNai5QuotaBlock(
          '你还没有 NAI5 出图资格。V5 额度只发给上线前用过 bot 出图的老用户,'
          '需要的话找管理员开通(其它模型不受影响,照常可用)',
        ),
        isTrue,
      );
    });

    test('别的失败不误判 —— 误判会让本该重试的失败不再重试', () {
      expect(isNai5QuotaBlock('队列已满,请稍后再试'), isFalse);
      expect(isNai5QuotaBlock('生成失败:连接超时'), isFalse);
      // 「NAI 5」带空格是服务端别处的写法,不是额度拒绝
      expect(isNai5QuotaBlock('NAI 5 模型暂不支持角色参考'), isFalse);
      expect(isNai5QuotaBlock('点数不足'), isFalse);
    });
  });
}
