import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/backend_client.dart';
import '../../core/theme/app_theme.dart';
import '../generate/gpu_rental.dart' show fmtUptime, fmtYuan;
import 'stats_providers.dart';
import 'stats_widgets.dart';

/// 算力账单二级页 —— 出图租卡 + 生成视频。
///
/// **和 NAI 那本不是一本账**,所以分两个入口而不是并成一页求和:
/// NAI 那本是订阅制月盘子按用量分摊出来的(阶梯、月结、有支付状态),
/// 这本是按次实付、直计不分摊(开一次机结一次、生一条视频扣一次)。
/// 两个数加在一起没有任何含义。
class GpuBillsPage extends ConsumerWidget {
  const GpuBillsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(gpuBillsProvider);
    final b = async.value;
    return Scaffold(
      appBar: AppBar(title: const Text('算力账单')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(gpuBillsProvider),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
          children: [
            if (async.isLoading && b == null)
              const _SumCard(bills: null)
            else if (b == null || !b.ok)
              const StatsCard(child: Text('账单加载失败,下拉重试')),
            if (b != null && b.ok) ...[
              if (b.isEmpty)
                // 刚结完账正是这个分支:本期空的,但上期账单还得看得见 ——
                // 不然用户会以为自己的消费记录凭空没了,而那笔钱恰恰是现在要付的。
                StatsCard(child: _EmptyHint(settled: b.settled))
              else ...[
                _SumCard(bills: b),
                if (b.running != null) ...[
                  const SizedBox(height: 10),
                  _RunningCard(running: b.running!),
                ],
                if (b.items.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _DetailCard(items: b.items),
                ],
              ],
              if (b.lastPeriod != null) ...[
                const SizedBox(height: 10),
                _LastPeriodCard(last: b.lastPeriod!),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({this.settled = false});

  /// 已经结过账:那这个「空」只是**本期**空,不是从来没花过。
  final bool settled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        settled ? '本期还没有算力消费' : '还没有算力消费',
        style: context.texts.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(
        '免费共享出图不计费,只有独享实例和生成视频才产生费用。',
        style: context.texts.bodySmall!.copyWith(
          color: context.scheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

/// 合计卡:总额 + 两项分列。
///
/// 两项**必须分开列**:一个按秒租机、一个按成片秒数,计价方式都不一样,
/// 只给一个总数的话用户没法核对自己哪部分花得多。
class _SumCard extends StatelessWidget {
  const _SumCard({required this.bills});

  /// null = 还在拉,整棵树换等高骨架,数据到位不跳版。
  final GpuBills? bills;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final b = bills;
    return StatsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.memory_outlined,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                // 结过账就只算这一期。没结过时口径仍是全部历史,照旧说「累计」。
                b?.settled == true ? '本期消费' : '累计消费',
                style: context.texts.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (b != null && b.ratePerHour > 0)
                Text(
                  '${b.ratePerHour.toStringAsFixed(2)} 元/时',
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (b == null)
            SkeletonText(
              sample: '¥000.00',
              style: mono(context, size: 24, weight: FontWeight.w700),
              width: 96,
            )
          else
            Text(
              fmtYuan(b.totalCost),
              style: mono(context, size: 24, weight: FontWeight.w700),
            ),
          // 结算点写出来,不然用户看不出这个数为什么突然变小了
          if (b != null && b.settled && b.periodLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                b.periodLabel,
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _Part(
                  icon: Icons.developer_board,
                  label: '出图租卡',
                  value: b == null ? null : fmtYuan(b.rentalCost),
                  sub: b == null
                      ? null
                      : '${b.rentalCount} 次 · ${b.rentalHours} 小时 · '
                            '出图 ${b.rentalJobs}',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Part(
                  icon: Icons.movie_outlined,
                  label: '生成视频',
                  value: b == null ? null : fmtYuan(b.videoCost),
                  sub: b == null
                      ? null
                      : '${b.videoCount} 条 · 共 ${b.videoSeconds} 秒',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '免费共享出图不计费',
            style: context.texts.labelSmall!.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

class _Part extends StatelessWidget {
  const _Part({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
  });

  final IconData icon;
  final String label;

  /// null = 骨架。
  final String? value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          if (value == null)
            SkeletonText(
              sample: '¥00.00',
              style: mono(context, size: 15, weight: FontWeight.w700),
              width: 58,
            )
          else
            Text(
              value!,
              style: mono(context, size: 15, weight: FontWeight.w700),
            ),
          const SizedBox(height: 2),
          if (sub == null)
            SkeletonText(
              sample: '0 次 · 0 小时',
              style: context.texts.labelSmall!,
              width: 86,
            )
          else
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
        ],
      ),
    );
  }
}

/// 上期账单:管理员结算那一刻定死的快照,**这才是真要付的钱**。
/// 和上面那张「本期消费」是两笔 —— 上期已经收口,本期还在涨。
class _LastPeriodCard extends StatelessWidget {
  const _LastPeriodCard({required this.last});

  final GpuLastPeriod last;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final parts = [
      if (last.rentalCount > 0)
        '租卡 ${last.rentalCount} 次 · ${last.rentalHours} 小时 '
            '${fmtYuan(last.rentalCost)}',
      if (last.videoCount > 0)
        '视频 ${last.videoCount} 条 · ${last.videoSeconds} 秒 '
            '${fmtYuan(last.videoCost)}',
    ];
    return StatsCard(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.receipt_outlined,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '上期账单',
                style: context.texts.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  last.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                fmtYuan(last.cost),
                style: mono(context, size: 17, weight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            parts.isEmpty ? '上期没有算力消费' : parts.join(' · '),
            style: context.texts.labelSmall!.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 还在跑的那台。单独标出来 —— 它的钱还在涨,和已结算的不是一回事。
/// (合计里已经把它算进去了:用户看的是「到现在为止花了多少」。)
class _RunningCard extends StatelessWidget {
  const _RunningCard({required this.running});

  final GpuBillRunning running;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return StatsCard(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '正在计费中',
                  style: context.texts.bodyMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '已运行 ${fmtUptime(running.seconds)} · '
                  '出图 ${running.jobsDone} 张',
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Text(
            fmtYuan(running.cost),
            style: mono(context, size: 15, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// 关机原因 → 人话。服务端存的是内部说法,直接显示会露出实现细节。
const _kStopReason = {
  '用户主动': '手动关机',
  '空闲超时': '空闲自动关机',
  '超过硬上限': '到最长时限自动关机',
  '失联': '连接中断,已停止计费',
};

/// 逐笔明细。租卡和视频混在一条时间线上,靠副行区分。
class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.items});

  final List<GpuBillItem> items;

  /// `2026-08-17T21:19:23` → `08-17 21:19`。服务端原样给 ISO 串,
  /// 这里只切不解析 —— 解析成 DateTime 会顺手做时区换算,而那串本来就是本地时间。
  static String _time(String iso) {
    if (iso.length < 16) return iso;
    return iso.substring(5, 16).replaceFirst('T', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return StatsCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '消费明细',
                style: context.texts.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '最近 ${items.length} 笔',
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          for (final it in items)
            LedgerRow(
              icon: it.isRental ? Icons.developer_board : Icons.movie_outlined,
              title: it.isRental ? '租卡 ${it.minutes} 分钟' : '视频 ${it.seconds} 秒',
              sub: [
                _time(it.time),
                if (it.isRental)
                  '出图 ${it.jobsDone}'
                      '${it.jobsFailed > 0 ? ' · 失败 ${it.jobsFailed}' : ''}'
                else if (it.preset.isNotEmpty)
                  it.preset,
                if (it.isRental && it.reason.isNotEmpty)
                  _kStopReason[it.reason] ?? it.reason,
              ].join(' · '),
              trailing: fmtYuan(it.cost),
              trailingColor: scheme.onSurface,
            ),
        ],
      ),
    );
  }
}
