import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/theme/app_theme.dart';
import 'stats_providers.dart';
import 'stats_widgets.dart';

/// 全平台统计二级页:当期四指标 + 历史全局 + 三张 24 小时热力图
/// (负载/活跃人数/平均耗时)。数据与接入模式无关,但服务端要求
/// Bot 会话;在线人数为公开端点,无会话也显示。
class PlatformPage extends ConsumerStatefulWidget {
  const PlatformPage({super.key});

  @override
  ConsumerState<PlatformPage> createState() => _PlatformPageState();
}

class _PlatformPageState extends ConsumerState<PlatformPage> {
  String _range = 'week';

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(botSessionProvider).value;
    final days = rangeDays[_range] ?? 7;

    return Scaffold(
      appBar: AppBar(title: const Text('全平台统计')),
      body: session == null
          ? ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
              children: const [
                StatsCard(child: Text('全平台统计需 Bot 授权后可见。在「我的 → 账号与接入」完成授权即可。')),
              ],
            )
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(platformStatsProvider);
                ref.invalidate(platformAllProvider);
                ref.invalidate(platformHourlyProvider);
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                children: [
                  RangeChips(
                    range: _range,
                    onChanged: (v) => setState(() => _range = v),
                  ),
                  const SizedBox(height: 12),
                  _statTiles(context),
                  const SizedBox(height: 10),
                  _allCard(context),
                  const SizedBox(height: 10),
                  HeatCard(
                    icon: Icons.stacked_line_chart,
                    title: '每日负载时段',
                    heat: ref.watch(
                      platformHourlyProvider((HourlyKind.calls, days)),
                    ),
                    peakText: (t) => '峰值 ${t.hour}:00(日均 ${fmtInt(t.avg)} 次)',
                    legend: true,
                  ),
                  const SizedBox(height: 10),
                  HeatCard(
                    icon: Icons.group_outlined,
                    title: '用户活跃时段',
                    heat: ref.watch(
                      platformHourlyProvider((HourlyKind.users, days)),
                    ),
                    peakText: (t) => '峰值 ${t.hour}:00(日均 ${fmtInt(t.avg)} 人)',
                  ),
                  const SizedBox(height: 10),
                  HeatCard(
                    icon: Icons.schedule,
                    title: '平均生成耗时',
                    heat: ref.watch(
                      platformHourlyProvider((HourlyKind.duration, days)),
                    ),
                    peakText: (t) =>
                        '最慢 ${t.hour}:00(平均 ${t.avg.toStringAsFixed(t.avg >= 10 ? 0 : 1)}s)',
                  ),
                ],
              ),
            ),
    );
  }

  Widget _statTiles(BuildContext context) {
    final async = ref.watch(platformStatsProvider(_range));
    final st = async.value;
    final loading = async.isLoading;
    return StatsCard(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.image_outlined,
                  label: '生图次数',
                  value: st == null ? null : fmtInt(st.imageCalls),
                  loading: loading,
                ),
              ),
              Expanded(
                child: StatTile(
                  icon: Icons.chat_bubble_outline,
                  label: 'AI 对话',
                  value: st == null ? null : fmtInt(st.aiCalls),
                  loading: loading,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.toll_outlined,
                  label: '点数消耗',
                  value: st == null ? null : fmtInt(st.pointsSpent),
                  loading: loading,
                ),
              ),
              Expanded(
                child: StatTile(
                  icon: Icons.group_outlined,
                  label: '活跃用户',
                  value: st == null ? null : fmtInt(st.activeUsers),
                  loading: loading,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _allCard(BuildContext context) {
    final scheme = context.scheme;
    final async = ref.watch(platformAllProvider);
    final all = async.value;
    final since = all?.firstRecord?.split('T').first;
    Widget cell(String label, int? v) => Expanded(
      child: Column(
        children: [
          if (async.isLoading && v == null)
            SkeletonText(
              sample: '0,000,000',
              style: mono(context, size: 13),
              width: 46,
            )
          else
            Text(v == null ? '—' : fmtInt(v), style: mono(context, size: 13)),
          const SizedBox(height: 2),
          Text(
            label,
            style: context.texts.labelSmall!.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
    return StatsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '历史全局',
                style: context.texts.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                since == null ? '' : '$since 起',
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              cell('总生图', all?.imageCalls),
              cell('总对话', all?.aiCalls),
              cell('总消耗', all?.pointsSpent),
              cell('总用户', all?.totalUsers),
            ],
          ),
        ],
      ),
    );
  }
}
