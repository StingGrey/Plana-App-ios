import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/theme/app_theme.dart';
import '../generate/widgets/common.dart' show sharedAxisRoute;
import '../shell/shell_state.dart';
import 'bot_auth_page.dart';

/// 首启引导:选接入方式 —— 直连自带 NAI Token / 通过 Bot 授权。
/// 由 main.dart 的启动 gate 在「尚未选择模式」时展示。
class OnboardingPage extends ConsumerWidget {
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 44, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.auto_awesome, size: 44, color: scheme.primary),
              const SizedBox(height: 18),
              Text('欢迎使用 Plana',
                  style: context.texts.headlineSmall!
                      .copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('选择一种接入方式开始,之后可随时在「我的」页切换。',
                  style: context.texts.bodyMedium!
                      .copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
              const SizedBox(height: 30),
              _ChoiceCard(
                icon: Icons.vpn_key,
                title: '直连 NovelAI Token',
                subtitle: '自带 NAI 持久令牌,直接连 NovelAI 生成,扣自己账户的 Anlas。',
                onTap: () {
                  // 先切到「我的」页(填令牌),再置模式触发 gate 换到 AppShell。
                  // 顺序不能反:set 会销毁本页,之后再用 ref 会报错。
                  ref.read(shellIndexProvider.notifier).select(kTabProfile);
                  ref.read(authModeProvider.notifier).set(AuthMode.token);
                },
              ),
              const SizedBox(height: 14),
              _ChoiceCard(
                icon: Icons.smart_toy_outlined,
                title: '通过 Bot 授权',
                subtitle: '用你在 QQ/Discord 的 Bot 账号授权,生成走后端、无需自备令牌。',
                accent: true,
                onTap: () => Navigator.of(context)
                    .push(sharedAxisRoute(const BotAuthPage())),
              ),
              const Spacer(),
              Text('令牌 / 会话都只加密存在本机。',
                  textAlign: TextAlign.center,
                  style: context.texts.labelSmall!
                      .copyWith(color: scheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final Color bg = accent ? scheme.primaryContainer : scheme.surfaceContainerLow;
    final Color fg = accent ? scheme.onPrimaryContainer : scheme.onSurface;
    final Color iconBg = accent ? scheme.primary : scheme.surfaceContainerHighest;
    final Color iconFg = accent ? scheme.onPrimary : scheme.primary;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 14, 18),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
                child: Icon(icon, size: 24, color: iconFg),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: context.texts.titleMedium!.copyWith(
                            fontWeight: FontWeight.w700, color: fg)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: context.texts.bodySmall!.copyWith(
                            color: fg.withValues(alpha: .75), height: 1.4)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, color: fg.withValues(alpha: .5)),
            ],
          ),
        ),
      ),
    );
  }
}
