import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_info.dart';
import '../../core/theme/app_theme.dart';
import '../gallery/upscale_model_store.dart' show kUpscaleModelSource;
import '../generate/widgets/common.dart' show hintSnack;
import '../update/update_sheet.dart' show UpdateRow;
import 'widgets/settings_ui.dart';

/// 关于:身份 + 出处 + 法律。
///
/// 只放**别处看不到、又必须交代**的东西:版本、第三方数据与模型的来源、
/// 开源许可、免责。设置项一律不进这里。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                // 真的应用图标(资源已按自适应图标几何预合成,见 pubspec)
                ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Image.asset(
                    'assets/app_icon.png',
                    width: 74,
                    height: 74,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  kAppName,
                  style: context.texts.titleLarge!.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  kAppTagline,
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$kAppVersion ($kAppBuild)',
                      style: mono(context, size: 12, color: scheme.outline),
                    ),
                    // 内测包发出去之后,反馈里最难对齐的就是"你装的是哪版",
                    // 版号旁边直接标出来
                    if (kIsPrerelease) ...[
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.tertiary.withValues(alpha: .16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '内测',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: scheme.tertiary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SettingsLabel('版本'),
          const SettingsCard(children: [UpdateRow()]),
          const SizedBox(height: 16),
          const SettingsLabel('数据与资源'),
          SettingsCard(
            children: [
              SettingsRow(
                icon: Icons.menu_book_outlined,
                title: '法典图鉴',
                value: 'quicktagcloud.com',
                onTap: () => _open(context, kCodexSourceUrl),
              ),
              const SettingsRow(
                icon: Icons.sell_outlined,
                title: '标签补全',
                value: 'Danbooru 离线库',
              ),
              SettingsRow(
                icon: Icons.hd_outlined,
                title: '本地超分',
                value: 'Upscayl 模型',
                onTap: () => _open(context, kUpscaleModelSource),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const SettingsLabel('法律'),
          SettingsCard(
            children: [
              // 填了 kGithubRepo 才出现 —— 同一个常量也驱动「检查更新」,
              // 一处配置点亮两个功能,不会出现"有源码入口但查不了更新"的错位
              if (kGithubRepo.isNotEmpty)
                SettingsRow(
                  icon: Icons.code,
                  title: '源码',
                  value: kGithubRepo,
                  onTap: () =>
                      _open(context, 'https://github.com/$kGithubRepo'),
                ),
              SettingsRow(
                icon: Icons.balance_outlined,
                title: '开源协议',
                value: kLicense,
                onTap: () => _open(context, kLicenseUrl),
              ),
              SettingsRow(
                icon: Icons.description_outlined,
                title: '第三方许可',
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: kAppName,
                  applicationVersion: '$kAppVersion ($kAppBuild)',
                  applicationLegalese: kLegalese,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '$kAppName 是第三方客户端,与 NovelAI 官方无关联。'
              '图像由 NovelAI 生成,账号与生成内容产生的一切责任由使用者承担。'
              '法典、标签与模型的版权归各自作者所有,本应用仅作索引与调用 —— '
              '本地超分模型不随应用分发,首次使用时由你的设备直接从 Upscayl 官方仓库下载。',
              style: context.texts.labelSmall!.copyWith(
                color: scheme.outline,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      hintSnack(context, '打不开浏览器', icon: Icons.link_off);
    }
  }
}
