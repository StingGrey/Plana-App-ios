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

  group('点数逐笔', () {
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
