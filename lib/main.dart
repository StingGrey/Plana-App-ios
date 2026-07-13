import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_mode.dart';
import 'core/theme/app_theme.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/shell/app_shell.dart';

void main() {
  runApp(const ProviderScope(child: PlanaApp()));
}

class PlanaApp extends StatelessWidget {
  const PlanaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plana',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // 先固定亮色预览;后续在「我的」页做 亮/暗/跟随系统 切换
      themeMode: ThemeMode.light,
      home: const _AuthGate(),
    );
  }
}

/// 启动 gate:未选接入方式 → 引导页;已选 → 主界面。
/// authModeProvider 首帧 loading 时垫占位,避免闪主界面。
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(authModeProvider);
    return mode.when(
      loading: () => const _SplashHold(),
      error: (_, _) => const OnboardingPage(), // 读失败按未选择处理
      data: (m) => m == null ? const OnboardingPage() : const AppShell(),
    );
  }
}

class _SplashHold extends StatelessWidget {
  const _SplashHold();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Icon(Icons.auto_awesome,
            size: 40, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
