import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import 'key_ledger.dart';
import 'stats_providers.dart';
import 'stats_widgets.dart';

/// 账单二级页(Key 直连):本机汇总(估算消耗 + 类型分布)+ 混排流水。
///
/// Bot 那边原来的服务端账单(上期结算 / 本期预估、阶梯全表)2026-10-18 起
/// 换成了钱包,见 WalletPage。
class LedgerPage extends ConsumerStatefulWidget {
  const LedgerPage({super.key, required this.range});

  final String range;

  @override
  ConsumerState<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends ConsumerState<LedgerPage> {
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
          children: _keyBody(context, ref),
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

  /// 累计行(生图 / 消耗)。[extra] 是接在后面的补充段(用来挂 V5 那截)。
  Widget _totalsLine(
    BuildContext context,
    int images,
    int pts, {
    String extra = '',
  }) {
    final scheme = context.scheme;
    return Row(
      children: [
        Text(
          '累计',
          style: context.texts.labelSmall!.copyWith(color: scheme.outline),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '${fmtInt(images)} 张 · ${fmtInt(pts)} 点$extra',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: context.texts.bodySmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
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
                        // V5 那截只在有量时才接上去,没用过的人摆个「V5 0 张」是噪音。
                        // 张数和点数一起给:V5 扣点是 V4.5 的 1.5 倍,只看张数
                        // 看不出真实消耗(与 Bot 那边同一口径)。
                        '免费生成 ${fmtInt(sum.free)} 张未计费'
                        '${sum.v5 > 0 ? ' · V5 ${fmtInt(sum.v5)} 张/${fmtInt(sum.v5Pts)} 点' : ''}',
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
                      _totalsLine(
                        context,
                        ledger.totalImages,
                        ledger.totalPts,
                        extra: ledger.totalV5 > 0
                            ? ' · V5 ${fmtInt(ledger.totalV5)} 张/'
                                  '${fmtInt(ledger.totalV5Pts)} 点'
                            : '',
                      ),
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

/// `yyyy-MM-dd` → 今天/昨天/MM-dd。
String _dayLabel(String key) {
  final now = DateTime.now();
  if (key == KeyLedgerStore.dayKey(now)) return '今天';
  if (key == KeyLedgerStore.dayKey(now.subtract(const Duration(days: 1)))) {
    return '昨天';
  }
  return key.length >= 10 ? key.substring(5) : key;
}
