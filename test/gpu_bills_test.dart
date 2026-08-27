// 算力账单的解析契约(`GET /api/rental/bills`)。
//
// 服务端把租卡和视频**两张表归并成一条时间线**再下发,合计分三块给:
// total_cost / rental{...} / video{...}。这里钉的是"我们有没有照它读"。
//
// ⚠ 返回里**只有售价**,机时成本和毛利服务端根本不下发 —— 别在 app 侧
//   凑一个出来(见 img_rental.bills 的注释)。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/backend_client.dart';

const _full = {
  'ok': true,
  'items': [
    {
      'kind': 'rental',
      'time': '2026-08-17T21:19:23.123456',
      'cost': 1.35,
      'seconds': 1800,
      'minutes': 30.0,
      'jobs_done': 12,
      'jobs_failed': 1,
      'reason': '空闲超时',
    },
    {
      'kind': 'video',
      'time': '2026-08-17T09:02:00.000001',
      'cost': 0.25,
      'seconds': 5,
      'preset': 'wan-i2v',
      'mode': '图生视频',
    },
  ],
  'running': {
    'instance_id': 'uhost-x',
    'seconds': 300,
    'minutes': 5.0,
    'jobs_done': 2,
    'cost': 0.23,
  },
  'total_cost': 1.83,
  'rental': {'cost': 1.58, 'hours': 0.6, 'jobs': 14, 'count': 3},
  'video': {'cost': 0.25, 'seconds': 5, 'count': 1},
  'rate_per_hour': 2.7,
};

void main() {
  test('完整返回:三块合计各就各位', () {
    final b = GpuBills.fromJson(_full);
    expect(b.ok, isTrue);
    expect(b.totalCost, 1.83);
    expect(b.rentalCost, 1.58);
    expect(b.rentalHours, 0.6);
    expect(b.rentalJobs, 14);
    expect(b.rentalCount, 3);
    expect(b.videoCost, 0.25);
    expect(b.videoSeconds, 5);
    expect(b.videoCount, 1);
    expect(b.ratePerHour, 2.7);
  });

  test('两类明细各读各的字段', () {
    final items = GpuBills.fromJson(_full).items;
    expect(items, hasLength(2));

    final r = items[0];
    expect(r.isRental, isTrue);
    expect(r.minutes, 30.0);
    expect(r.jobsDone, 12);
    expect(r.jobsFailed, 1);
    expect(r.reason, '空闲超时');

    final v = items[1];
    expect(v.isRental, isFalse);
    expect(v.seconds, 5);
    expect(v.preset, 'wan-i2v');
    // 视频那条没有 minutes / jobs_done,不能因此崩,给 0 就行
    expect(v.minutes, 0);
    expect(v.jobsDone, 0);
  });

  // 在跑的那台合计里已经算进去了,但它的钱**还在涨** ——
  // 界面要单独标出来,所以解析必须把它和已结算的分开拿到
  test('在跑的那台单独出来', () {
    final b = GpuBills.fromJson(_full);
    expect(b.running, isNotNull);
    expect(b.running!.seconds, 300);
    expect(b.running!.jobsDone, 2);
    expect(b.running!.cost, 0.23);
    expect(b.isEmpty, isFalse);
  });

  test('没在跑时 running 是 null,不是空对象', () {
    final b = GpuBills.fromJson({..._full, 'running': null});
    expect(b.running, isNull);
  });

  // 表还没建 = 还没人租过,服务端照样回 ok
  test('一分钱没花过:isEmpty', () {
    final b = GpuBills.fromJson(const {
      'ok': true,
      'items': [],
      'running': null,
      'total_cost': 0,
      'rental': {'cost': 0, 'hours': 0, 'jobs': 0, 'count': 0},
      'video': {'cost': 0, 'seconds': 0, 'count': 0},
      'rate_per_hour': 2.7,
    });
    expect(b.ok, isTrue);
    expect(b.isEmpty, isTrue);
    expect(b.totalCost, 0);
  });

  test('出错返回:ok=false,带上原因,不抛', () {
    final b = GpuBills.fromJson(const {
      'ok': false,
      'items': [],
      'message': 'OperationalError',
    });
    expect(b.ok, isFalse);
    expect(b.message, 'OperationalError');
    expect(b.items, isEmpty);
  });

  test('缺字段一律按 0 / 空,不抛', () {
    final b = GpuBills.fromJson(const {});
    expect(b.ok, isFalse);
    expect(b.items, isEmpty);
    expect(b.running, isNull);
    expect(b.totalCost, 0);
    expect(b.rentalHours, 0);
    expect(b.ratePerHour, 0);
    expect(b.isEmpty, isTrue);
  });

  // 服务端存的是 datetime.now().isoformat(),没有时区。界面上只切不解析 ——
  // 解析成 DateTime 会顺手做时区换算,而那串本来就是本地时间
  test('时间串按位切得出「月-日 时:分」', () {
    const iso = '2026-08-17T21:19:23.123456';
    expect(iso.substring(5, 16).replaceFirst('T', ' '), '08-17 21:19');
  });
}
