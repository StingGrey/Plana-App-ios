import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/backend_client.dart';
import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import 'key_ledger.dart';
import 'stats_providers.dart';
import 'stats_widgets.dart';

/// 账单二级页。Bot:服务端账单(上期结算默认,可切本期预估;阶梯全表)
/// + 每日流水;Key:本机汇总(估算消耗 + 类型分布)+ 混排流水。
class LedgerPage extends ConsumerStatefulWidget {
  const LedgerPage({super.key, required this.bot, required this.range});

  final bool bot;
  final String range;

  @override
  ConsumerState<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends ConsumerState<LedgerPage> {
  /// Bot 账单卡当前期:true = 上期结算(默认),false = 本期预估。
  bool _prev = true;

  bool get bot => widget.bot;
  String get range => widget.range;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('账单')),
      // 外层不滚:汇总卡固定在上,流水卡撑满剩余高度、内部自滚
      body: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: bot ? _botBody(context, ref) : _keyBody(context, ref),
        ),
      ),
    );
  }

  /// 流水卡:标题固定,行在卡内滚动(外层高度由 Expanded 撑满屏幕)。
  Widget _flowCard(
    BuildContext context, {
    required String title,
    String? trailing,
    required List<Widget> rows,
    Widget? footer,
  }) {
    final scheme = context.scheme;
    return StatsCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                title,
                style: context.texts.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (trailing != null)
                Text(
                  trailing,
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              children: rows,
            ),
          ),
          ?footer,
        ],
      ),
    );
  }

  // ── Bot:服务端账单 ────────────────

  List<Widget> _botBody(BuildContext context, WidgetRef ref) {
    final async = ref.watch(
      _prev ? billingSettlementProvider : billingEstimateProvider,
    );
    final daily = ref.watch(userDailyProvider('month'));
    return [
      _billCard(context, ref, async.value, async.isLoading),
      const SizedBox(height: 10),
      Expanded(
        child: _flowCard(
          context,
          title: '流水 · 每日',
          trailing: '本月',
          rows: _botDailyRows(context, daily.value, daily.isLoading),
        ),
      ),
    ];
  }

  /// 账单卡(对齐 web 结算弹窗):期切换 + 应付/预估金额 + 本人行 +
  /// 阶梯全表(区间/人数/人均,本人所在行高亮)。加载态与最终态同一棵树,
  /// 叶子换等高骨架,数据到位不跳版。
  Widget _billCard(
    BuildContext context,
    WidgetRef ref,
    BillingReport? r,
    bool isLoading,
  ) {
    final scheme = context.scheme;
    final loading = isLoading && r == null;
    if (!loading && r == null) {
      return const StatsCard(child: Text('账单加载失败,退出重进或稍后再试'));
    }
    final me = r?.me;
    final myTier = me?.tierName ?? (r?.paymentStatus == 'free' ? '免费' : '');
    // 人少走均摊时只有 免费/均摊 两档
    final tiers = (r?.distribution.containsKey('均摊') ?? false)
        ? const ['免费', '均摊']
        : const ['免费', '一阶', '二阶', '三阶'];

    Widget headCell(
      String t, {
      int flex = 2,
      TextAlign align = TextAlign.right,
    }) => Expanded(
      flex: flex,
      child: Text(
        t,
        textAlign: align,
        style: context.texts.labelSmall!.copyWith(color: scheme.outline),
      ),
    );

    return StatsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.receipt_long_outlined,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                _prev ? '上期账单' : '本期预估',
                style: context.texts.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              if (loading)
                SkeletonText(
                  sample: '00/00 - 00/00',
                  style: context.texts.labelSmall!,
                  width: 64,
                )
              else
                Text(
                  r!.periodLabel,
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
              const Spacer(),
              _PeriodSeg(
                prev: _prev,
                onChanged: (v) => setState(() => _prev = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (loading)
                SkeletonText(
                  sample: '¥000',
                  style: mono(context, size: 24, weight: FontWeight.w700),
                  width: 62,
                )
              else
                Text(
                  '¥${fmtInt(me?.totalFee ?? 0)}',
                  style: mono(context, size: 24, weight: FontWeight.w700),
                ),
              const SizedBox(width: 8),
              if (!loading)
                Text(
                  _prev ? _payLabel(r!.paymentStatus) : '预估 · 27 日结算',
                  style: context.texts.labelSmall!.copyWith(
                    color: !_prev
                        ? scheme.outline
                        : r!.paymentStatus == 'unpaid'
                        ? scheme.error
                        : scheme.tertiary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (loading)
            SkeletonText(
              sample: '生图 000 张 · Anlas 0,000',
              style: context.texts.bodySmall!,
              width: 168,
            )
          else
            Text(
              me == null
                  ? '本期无生图记录'
                  : '生图 ${fmtInt(me.imageCalls)} 张 · '
                        'Anlas ${fmtInt(me.anlasUsed)}'
                        '${myTier.isEmpty ? '' : ' · $myTier'}',
              style: context.texts.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          const CardDivider(),
          Row(
            children: [
              headCell('阶梯', flex: 2, align: TextAlign.left),
              headCell('张数区间', flex: 3),
              headCell('人数', flex: 2),
              headCell('人均', flex: 2),
            ],
          ),
          const SizedBox(height: 2),
          if (loading)
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: SkeletonBox(width: double.infinity, height: 13),
              )
          else
            for (final tier in tiers) _tierRow(context, r!, tier, myTier),
          // 累计(跨周期),放明细页收着
          const CardDivider(),
          _totalsLine(
            context,
            ref.watch(userStatsAllProvider).value?.imageCalls,
            ref.watch(userStatsAllProvider).value?.pointsSpent,
            loading: ref.watch(userStatsAllProvider).isLoading,
          ),
        ],
      ),
    );
  }

  /// 阶梯表一行:阶梯 | 张数区间 | 人数 | 人均;本人所在行高亮。
  Widget _tierRow(
    BuildContext context,
    BillingReport r,
    String tier,
    String myTier,
  ) {
    final scheme = context.scheme;
    final row = r.distribution[tier];
    final mine = tier == myTier;
    final avg = r.avgFeeOf(tier);
    final String fee;
    if (tier == '免费') {
      fee = '¥0';
    } else if (avg != null) {
      fee = _prev ? '¥${fmtInt(avg)}' : '~¥${fmtInt(avg)}';
    } else {
      fee = r.earlyMode && tier == '三阶' ? '≤¥25' : '—';
    }
    Widget cell(
      String t, {
      int flex = 2,
      TextAlign align = TextAlign.right,
      Color? color,
    }) => Expanded(
      flex: flex,
      child: Text(
        t,
        textAlign: align,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.texts.labelMedium!.copyWith(
          color:
              color ??
              (mine ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: mine
          ? BoxDecoration(
              color: scheme.secondaryContainer.withValues(alpha: .4),
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Row(
        children: [
          cell(tier, flex: 2, align: TextAlign.left),
          cell(r.rangeOf(tier), flex: 3, color: mine ? null : scheme.outline),
          cell(row == null ? '—' : '${row.count} 人', flex: 2),
          cell(fee, flex: 2),
        ],
      ),
    );
  }

  /// 结算支付态文案:后端 payment_status ∈ paid / unpaid / free
  /// (free = 免费用户或无生图,无需支付)。付款流程留在 web,app 只读。
  static String _payLabel(String status) => switch (status) {
    'paid' => '已支付',
    'free' => '无需支付',
    'unpaid' => '待支付(去 web 端)',
    _ => '',
  };

  /// 累计行(生图 / 消耗),两种模式共用一套版式。
  Widget _totalsLine(
    BuildContext context,
    int? images,
    int? pts, {
    bool loading = false,
  }) {
    final scheme = context.scheme;
    return Row(
      children: [
        Text(
          '累计',
          style: context.texts.labelSmall!.copyWith(color: scheme.outline),
        ),
        const Spacer(),
        if (loading && images == null)
          SkeletonText(
            sample: '0,000 张 · 00,000 点',
            style: context.texts.bodySmall!,
            width: 116,
          )
        else
          Text(
            '${images == null ? '—' : fmtInt(images)} 张 · '
            '${pts == null ? '—' : fmtInt(pts)} 点',
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  List<Widget> _botDailyRows(
    BuildContext context,
    List<DailyStat>? daily,
    bool loading,
  ) {
    final scheme = context.scheme;
    if (daily == null) {
      // 骨架行与 LedgerRow 等高(图标 30 + 上下各 7),拉到数据不跳版
      if (loading) {
        return [
          for (var i = 0; i < 3; i++)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  SkeletonBox(width: 30, height: 30, radius: 9),
                  SizedBox(width: 10),
                  Expanded(child: SkeletonBox(width: 120, height: 12)),
                ],
              ),
            ),
        ];
      }
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '暂不可用',
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
        ),
      ];
    }
    final rows = [
      for (final d in daily.reversed)
        if (d.imageCalls > 0) d,
    ];
    if (rows.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '本月暂无生图记录',
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
        ),
      ];
    }
    return [
      for (final d in rows.take(20))
        LedgerRow(
          icon: Icons.image_outlined,
          title: '${_dayLabel(d.date)} · 生图 ${fmtInt(d.imageCalls)} 张',
          trailing: d.pointsSpent > 0 ? '-${fmtInt(d.pointsSpent)} 点' : '免费',
          trailingColor: d.pointsSpent > 0 ? scheme.primary : scheme.tertiary,
        ),
    ];
  }

  // ── Key:本机账单 ────────────────

  List<Widget> _keyBody(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final ledger = ref.watch(appStoresProvider).ledger;
    return [
      // Expanded 先把高度定死,里层的流水卡才能拿到有界约束去内部滚动
      Expanded(
        child: ListenableBuilder(
          listenable: ledger.rev,
          builder: (context, _) {
            final sum = ledger.sumRange(range);
            final total = sum.genPts + sum.vibePts + sum.upsPts;
            final maxPts = [
              sum.genPts,
              sum.vibePts,
              sum.upsPts,
            ].fold(1, (m, v) => v > m ? v : m);
            return Column(
              children: [
                StatsCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.receipt_long_outlined,
                            size: 15,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '本机账单',
                            style: context.texts.bodyMedium!.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            rangeLabels[range] ?? '',
                            style: context.texts.labelSmall!.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '${fmtInt(total)} 点',
                            style: mono(
                              context,
                              size: 24,
                              weight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '估算消耗',
                            style: context.texts.labelSmall!.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '免费生成 ${fmtInt(sum.free)} 张未计费',
                        style: context.texts.bodySmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const CardDivider(),
                      _typeBar(
                        context,
                        Icons.image_outlined,
                        '生图(计费)',
                        sum.genPts,
                        maxPts,
                      ),
                      const SizedBox(height: 8),
                      _typeBar(
                        context,
                        Icons.palette_outlined,
                        'Vibe 编码',
                        sum.vibePts,
                        maxPts,
                      ),
                      const SizedBox(height: 8),
                      _typeBar(
                        context,
                        Icons.zoom_in,
                        '超分',
                        sum.upsPts,
                        maxPts,
                      ),
                      const CardDivider(),
                      _totalsLine(context, ledger.totalImages, ledger.totalPts),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _flowCard(
                    context,
                    title: '流水',
                    trailing: '最近',
                    rows: _keyRows(context, ledger),
                    footer: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '本机记录 · 估算值,与 NAI 实扣可能略有出入',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ];
  }

  Widget _typeBar(
    BuildContext context,
    IconData icon,
    String label,
    int pts,
    int max,
  ) {
    final scheme = context.scheme;
    return Row(
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: context.texts.labelMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: max <= 0 ? 0 : pts / max,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHigh,
              color: scheme.primary,
            ),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            '${fmtInt(pts)} 点',
            textAlign: TextAlign.right,
            style: mono(context, size: 11),
          ),
        ),
      ],
    );
  }

  List<Widget> _keyRows(BuildContext context, KeyLedgerStore ledger) {
    final scheme = context.scheme;
    final rows = ledger.recentRows();
    if (rows.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '暂无记录。直连模式的生成会从现在开始记入。',
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
        ),
      ];
    }
    return [
      for (final r in rows)
        if (r.gen != null)
          LedgerRow(
            icon: Icons.image_outlined,
            title: '${_dayLabel(r.day!)} · 生图 ${fmtInt(r.gen!.images)} 张',
            sub: r.gen!.free == r.gen!.images
                ? '全部免费'
                : '免费 ${fmtInt(r.gen!.free)} · '
                      '计费 ${fmtInt(r.gen!.images - r.gen!.free)}',
            trailing: r.gen!.pts > 0 ? '-${fmtInt(r.gen!.pts)} 点' : '免费',
            trailingColor: r.gen!.pts > 0 ? scheme.primary : scheme.tertiary,
          )
        else
          LedgerRow(
            icon: r.op!.type == 'upscale'
                ? Icons.zoom_in
                : Icons.palette_outlined,
            title:
                '${_dayLabel(KeyLedgerStore.dayKey(DateTime.fromMillisecondsSinceEpoch(r.op!.ts)))}'
                ' · ${r.op!.type == 'upscale' ? '超分 4x' : 'Vibe 编码'}',
            trailing: '-${fmtInt(r.op!.pts)} 点',
          ),
    ];
  }
}

/// 上期 / 本期 切换胶囊。
class _PeriodSeg extends StatelessWidget {
  const _PeriodSeg({required this.prev, required this.onChanged});

  final bool prev;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    Widget seg(bool isPrev, String label) {
      final on = prev == isPrev;
      return Material(
        color: on ? scheme.secondaryContainer : Colors.transparent,
        child: InkWell(
          onTap: () => onChanged(isPrev),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              label,
              style: context.texts.labelSmall!.copyWith(
                color: on
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg(true, '上期'), seg(false, '本期')],
      ),
    );
  }
}

/// `yyyy-MM-dd` → 今天/昨天/MM-dd。
String _dayLabel(String key) {
  final now = DateTime.now();
  if (key == KeyLedgerStore.dayKey(now)) return '今天';
  if (key == KeyLedgerStore.dayKey(now.subtract(const Duration(days: 1)))) {
    return '昨天';
  }
  return key.length >= 10 ? key.substring(5) : key;
}
