import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;
import '../profile/widgets/settings_ui.dart';
import 'cloud_sync_progress.dart';
import 'cloud_sync_state.dart';

/// iCloud 同步:选一个 iCloud Drive 文件夹,作品原图备份进去,
/// 其他设备选同一个文件夹即可互通。机制见 cloud_sync_engine.dart。
class CloudSyncPage extends ConsumerWidget {
  const CloudSyncPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(cloudSyncProvider);
    final notifier = ref.read(cloudSyncProvider.notifier);
    final configured = s.folder?.configured == true;

    Future<void> pick() async {
      final picked = await notifier.pickFolder();
      if (!context.mounted) return;
      final error = ref.read(cloudSyncProvider).error;
      if (picked != null && picked.ready) {
        hintSnack(
          context,
          '已选择「${picked.name ?? '同步文件夹'}」，开始同步',
          icon: Icons.cloud_done_outlined,
        );
      } else if (error != null) {
        hintSnack(context, error, icon: Icons.error_outline);
      }
    }

    Future<void> syncNow({bool restoreAll = false}) async {
      final report = await notifier.sync(restoreAll: restoreAll);
      if (!context.mounted) return;
      final error = ref.read(cloudSyncProvider).error;
      if (report == null || error != null) {
        if (error != null) {
          hintSnack(context, error, icon: Icons.error_outline);
        }
        return;
      }
      hintSnack(
        context,
        report.uploaded + report.downloaded == 0 && report.waiting == 0
            ? '已经是最新的了'
            : _summary(report.uploaded, report.downloaded, report.waiting),
        icon: Icons.check_circle_outline,
      );
    }

    Future<void> restoreAll() async {
      final ok = await confirmDialog(
        context,
        title: '从文件夹恢复全部',
        message: '把文件夹里本机没有的图全部导入本地图库，包括之前在本机删掉的。',
        confirmLabel: '恢复',
        danger: false,
      );
      if (ok) await syncNow(restoreAll: true);
    }

    Future<void> disconnect() async {
      final ok = await confirmDialog(
        context,
        title: '断开同步文件夹',
        message: '之后不再自动同步。文件夹里的图和本机图库都会保留。',
        confirmLabel: '断开',
      );
      if (ok) await notifier.disconnect();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('iCloud 同步')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          if (!s.supported)
            const _Note('iCloud 同步目前只在 iOS 上可用。')
          else ...[
            _StatusCard(
              state: s,
              onPick: s.running ? null : pick,
              onSync: s.running ? null : syncNow,
            ),
            const SizedBox(height: 18),
            const SettingsLabel('同步方式'),
            SettingsCard(
              children: [
                _SwitchRow(
                  title: '自动同步',
                  subtitle: '出新图、回到应用时自动同步',
                  value: s.settings.auto,
                  onChanged: notifier.setAuto,
                ),
                _SwitchRow(
                  title: '拉取其他设备的图片',
                  subtitle: '关掉后只把本机作品备份上去',
                  value: s.settings.pull,
                  onChanged: notifier.setPull,
                ),
              ],
            ),
            if (configured) ...[
              const SizedBox(height: 18),
              const SettingsLabel('文件夹'),
              SettingsCard(
                children: [
                  SettingsRow(
                    icon: Icons.drive_folder_upload_outlined,
                    title: '更换文件夹',
                    value: s.folder?.name,
                    onTap: s.running ? null : pick,
                  ),
                  SettingsRow(
                    icon: Icons.settings_backup_restore,
                    title: '从文件夹恢复全部',
                    onTap: s.running || s.folder?.ready != true
                        ? null
                        : restoreAll,
                  ),
                  SettingsRow(
                    icon: Icons.link_off,
                    title: '断开文件夹',
                    onTap: s.running ? null : disconnect,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            const _Note(
              '原图以 PNG 存进文件夹，生成参数一并保留；另一台设备选同一个文件夹就能互相同步。\n'
              '删除不会同步：在哪台设备删都只删本机，文件夹里的图请到「文件」App 里删。\n'
              '其他设备刚传上来的图需要 iCloud 先下载，可能要等一会儿才出现。\n'
              '选文件夹时点「打开」没反应：多半是重签时包名和描述文件的 App ID 不一致，'
              '把包名改成描述文件里的 App ID 再签名安装。',
            ),
          ],
        ],
      ),
    );
  }
}

String _summary(int uploaded, int downloaded, int waiting) => [
  if (uploaded > 0) '上传 $uploaded 张',
  if (downloaded > 0) '拉取 $downloaded 张',
  if (waiting > 0) '$waiting 张等待 iCloud 下载',
].join(' · ');

String _fmtTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '今天 $hm';
  }
  return '${t.month}月${t.day}日 $hm';
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.state,
    required this.onPick,
    required this.onSync,
  });

  final CloudSyncState state;
  final VoidCallback? onPick;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final folder = state.folder;
    final ready = folder?.ready == true;
    final report = state.lastReport;

    final String title;
    final String detail;
    var detailColor = scheme.onSurfaceVariant;
    if (folder == null) {
      title = '正在读取…';
      detail = '';
    } else if (!folder.configured) {
      title = '还没有选择文件夹';
      detail = '在「文件」里选 iCloud Drive 中的一个文件夹（可以新建一个），作品会自动备份进去。';
    } else if (!folder.available) {
      title = folder.name ?? '同步文件夹';
      detail = '找不到这个文件夹，可能被移动、删除，或 iCloud 已退出登录。请重新选择。';
      detailColor = scheme.error;
    } else if (state.running) {
      title = folder.name ?? '同步文件夹';
      detail = cloudSyncProgressText(state)!;
    } else if (state.error != null) {
      title = folder.name ?? '同步文件夹';
      detail = state.error!;
      detailColor = scheme.error;
    } else {
      title = folder.name ?? '同步文件夹';
      final last = state.lastSyncAt > 0
          ? '上次同步 ${_fmtTime(state.lastSyncAt)}'
          : '还没同步过';
      final summary = report == null
          ? ''
          : _summary(report.uploaded, report.downloaded, report.waiting);
      detail = summary.isEmpty ? last : '$last · $summary';
    }

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  ready ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                  color: ready ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.titleSmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                detail,
                style: context.texts.bodySmall!.copyWith(color: detailColor),
              ),
            ],
            if (state.running) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: cloudSyncProgressValue(state)),
            ],
            const SizedBox(height: 14),
            if (ready)
              FilledButton.icon(
                onPressed: onSync,
                icon: const Icon(Icons.sync),
                label: const Text('立即同步'),
              )
            else if (folder != null)
              FilledButton.icon(
                onPressed: onPick,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(
                  folder.configured ? '重新选择文件夹' : '选择 iCloud Drive 文件夹',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: Text(
        title,
        style: context.texts.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle),
      contentPadding: const EdgeInsets.fromLTRB(16, 2, 10, 2),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        text,
        style: context.texts.bodySmall!.copyWith(
          color: context.scheme.onSurfaceVariant,
          height: 1.6,
        ),
      ),
    );
  }
}
