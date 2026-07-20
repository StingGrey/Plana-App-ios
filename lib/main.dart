import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_mode.dart';
import 'core/store/app_stores.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_settings.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/shell/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动装载持久化状态(工作台存档 + 图库索引;失败按首启空档降级)
  final stores = await AppStores.open();
  final themeInit = await loadThemeSettings(); // 预读外观,首帧不闪色
  runApp(
    ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        themeInitProvider.overrideWithValue(themeInit),
      ],
      child: const PlanaApp(),
    ),
  );
  // 注册即挂到 binding 观察者列表(强引用,不会被 GC):
  // 退后台/失焦即刻把防抖窗口里的工作台/图库索引落盘,进程被杀不丢。
  AppLifecycleListener(
    onStateChange: (s) {
      if (s == AppLifecycleState.inactive || s == AppLifecycleState.paused) {
        stores.flushNow();
      }
    },
  );
  stores.postBootMaintenance(); // 选图器缓存清扫 + blob GC(延迟后台跑)
}

class PlanaApp extends ConsumerWidget {
  const PlanaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = ref.watch(themeSettingsProvider);
    return MaterialApp(
      title: 'Plana',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(ts.seed.color),
      darkTheme: AppTheme.dark(ts.seed.color),
      themeMode: ts.mode,
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
