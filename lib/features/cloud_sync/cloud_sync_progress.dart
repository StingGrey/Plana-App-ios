import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_sync_engine.dart';
import 'cloud_sync_state.dart';

/// 同步进度的一句话;没在同步时返回 null —— 同步完不留在界面上。
String? cloudSyncProgressText(CloudSyncState s) {
  if (!s.running) return null;
  return switch (s.phase) {
    CloudSyncPhase.uploading when s.total > 0 => '正在上传 ${s.done} / ${s.total}',
    CloudSyncPhase.pulling when s.total > 0 => '正在拉取 ${s.done} / ${s.total}',
    _ => '正在检查文件夹…',
  };
}

/// 进度条的值。检查阶段还不知道要干多少活,返回 null 走不定进度。
double? cloudSyncProgressValue(CloudSyncState s) {
  if (!s.running || s.phase == CloudSyncPhase.checking || s.total <= 0) {
    return null;
  }
  return (s.done / s.total).clamp(0.0, 1.0);
}

/// 「我的」导航图标:同步进行时角上挂一枚小胶囊(↑ 上传 / ↓ 拉取 + 百分比),
/// 自动同步在后台跑时不进同步页也看得到;跑完自动收起。
class CloudSyncTabIcon extends ConsumerWidget {
  const CloudSyncTabIcon({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(cloudSyncProvider);
    final text = cloudSyncProgressText(s);
    if (text == null) return child;
    final scheme = Theme.of(context).colorScheme;
    final value = cloudSyncProgressValue(s);
    final icon = switch (s.phase) {
      CloudSyncPhase.uploading => Icons.arrow_upward,
      CloudSyncPhase.pulling => Icons.arrow_downward,
      CloudSyncPhase.checking => Icons.sync,
    };
    return Semantics(
      label: 'iCloud $text',
      child: Badge(
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: scheme.onPrimary),
            if (value != null) Text('${(value * 100).floor()}%'),
          ],
        ),
        child: child,
      ),
    );
  }
}
