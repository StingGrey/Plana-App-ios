import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_info.dart';
import 'core/auth/auth_mode.dart';
import 'core/platform/drop_import.dart';
import 'core/store/app_stores.dart';
import 'core/store/gen_settings.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_settings.dart';
import 'core/util/haptics.dart';
import 'features/generate/widgets/common.dart' show sharedAxisRoute;
import 'features/import/import_panel.dart';
import 'features/onboarding/welcome_page.dart';
import 'features/shell/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动装载持久化状态(工作台存档 + 图库索引 + 设置;失败按首启空档降级)。
  // 外观预读(首帧不闪色)现在直接取内存态 —— 设置已随 AppStores 一次读全,
  // 不再需要第二笔 I/O,也不必再解一次 Keystore。
  final stores = await AppStores.open();
  final themeInit = loadThemeSettings(stores.prefs);
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

class PlanaApp extends ConsumerStatefulWidget {
  const PlanaApp({super.key});

  @override
  ConsumerState<PlanaApp> createState() => _PlanaAppState();
}

class _PlanaAppState extends ConsumerState<PlanaApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final DropImportBridge _dropBridge;
  bool _dropPanelOpen = false;

  @override
  void initState() {
    super.initState();
    _dropBridge = DropImportBridge();
    _dropBridge.attach(_openDroppedImage);
  }

  @override
  void dispose() {
    _dropBridge.detach();
    super.dispose();
  }

  Future<void> _openDroppedImage(DroppedImage image) async {
    if (_dropPanelOpen || !mounted) return;
    var navigator = _navigatorKey.currentState;
    if (navigator == null) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      navigator = _navigatorKey.currentState;
    }
    if (navigator == null) return;

    _dropPanelOpen = true;
    try {
      await navigator.push<void>(
        sharedAxisRoute(
          ImportImagePanel(
            bytes: image.bytes,
            fileName: image.fileName,
            displayName: image.displayName,
          ),
        ),
      );
    } finally {
      _dropPanelOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = ref.watch(themeSettingsProvider);
    // 触感开关同步到全局出口:调用点在手势/绘制层,拿不到 ref,只能这样递。
    Haptics.enabled = ts.haptics;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(ts.seed.color),
      darkTheme: AppTheme.dark(ts.seed.color),
      themeMode: ts.mode,
      home: const _AuthGate(),
    );
  }
}

/// 启动 gate:欢迎流程没走完(没过通知那步)或没选接入方式 → 欢迎页;
/// 否则主界面。首帧 loading 时垫占位,避免闪主界面。
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(authModeProvider);
    final gs = ref.watch(genSettingsProvider);
    if (mode.isLoading || gs.isLoading) return const _SplashHold();
    // 读失败一律按首启处理:宁可多走一次欢迎,也不让人卡在空界面
    final primed = gs.value?.notifyPrimed ?? false;
    if (!primed || mode.value == null) return const WelcomePage();
    return const AppShell();
  }
}

class _SplashHold extends StatelessWidget {
  const _SplashHold();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Icon(
          Icons.auto_awesome,
          size: 40,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
