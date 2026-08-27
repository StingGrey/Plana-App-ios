import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/generate/widgets/anlas_panel.dart';

/// 「我的 NAI 5 额度」(`GET /api/user/quota`)的解析与读数。
///
/// 这块和池子那块电池(见 nai_usage_test)长得像但是两回事,而且几个缺省值
/// 一旦错了都是**静默**错:老服务端没有的字段兜错方向,用户会看到一块假的
/// 「无资格」;余额向上取整则会报 1 张、点进去却扣不动。钉住。
void main() {
  group('响应解析', () {
    test('正常一份', () {
      final q = NaiQuota.fromJson(const {
        'daily_balance': 137.4,
        'daily_limit': 200,
        'extra_balance': 20.0,
        'total_available': 157.4,
        'activated': true,
        'is_admin': false,
        'free_mode': false,
        'refill_per_day': 200.0,
      });
      expect(q.balance, 137.4);
      expect(q.limit, 200);
      expect(q.extra, 20);
      expect(q.activated, isTrue);
      expect(q.refillPerDay, 200);
    });

    test('老服务端缺字段 → 按「有资格、非管理员、没开免额度」兜', () {
      final q = NaiQuota.fromJson(const {
        'daily_balance': 8,
        'daily_limit': 200,
      });
      // activated 兜 true:兜成 false 会平白多出一块「无资格」的假警报
      expect(q.activated, isTrue);
      expect(q.isAdmin, isFalse);
      expect(q.freeMode, isFalse);
      expect(q.extra, 0);
    });

    test('无资格是显式的 false,不是「没有余额」', () {
      final q = NaiQuota.fromJson(const {
        'daily_balance': 0,
        'daily_limit': 200,
        'activated': false,
      });
      expect(q.activated, isFalse);
      expect(q.available, 0);
    });
  });

  group('读数', () {
    test('可用张数 = 余额 + 赠送,且**向下**取整', () {
      // 0.9 张扣不动,报成 1 张会让人点了才发现出不了图
      expect(NaiQuota.fromJson(const {'daily_balance': 0.9}).available, 0);
      expect(
        NaiQuota.fromJson(const {
          'daily_balance': 12.7,
          'extra_balance': 5.0,
        }).available,
        17,
      );
    });

    test('水位按余额/上限,赠送额不参与 —— 它不受上限封顶,并进来会超过 100%', () {
      final q = NaiQuota.fromJson(const {
        'daily_balance': 50.0,
        'daily_limit': 200,
        'extra_balance': 500.0,
      });
      expect(quotaPct(q), 25);
    });

    test('上限为 0 时水位按 0,不除零', () {
      expect(quotaPct(NaiQuota.fromJson(const {'daily_balance': 3})), 0);
    });
  });
}
