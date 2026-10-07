import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_info.dart';
import 'core/auth/auth_mode.dart';
import 'core/auth/credential_store.dart';
import 'core/auth/secure_storage.dart';
import 'core/platform/drop_import.dart';
import 'core/store/app_stores.dart';
import 'core/store/gen_settings.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_settings.dart';
import 'core/ui/input_focus_guard.dart';
import 'core/ui/nav_bar_guard.dart';
import 'core/util/haptics.dart';
import 'core/util/image_scramble.dart' show registerPngPkgLicense;
import 'features/generate/widgets/common.dart' show hintSnack, sharedAxisRoute;
import 'features/import/import_panel.dart';
import 'features/onboarding/welcome_page.dart';
import 'features/profile/account_page.dart';
import 'features/shell/app_shell.dart';
import 'features/editor/data/local_tag_db.dart';

final _inputFocusGuard = InputFocusGuard();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerPngPkgLicense();
  final tagDb = LocalTagDb();
  final tagDbReady = tagDb.install();
  // 启动装载持久化状态(工作台存档 + 图库索引 + 设置;失败按首启空档降级)。
  // 外观预读(首帧不闪色)现在直接取内存态 —— 设置已随 AppStores 一次读全,
  // 不再需要第二笔 I/O,也不必再解一次 Keystore。
  final stores = await AppStores.open();
  // 凭据出口:平时走 Keystore 加密存储,这台机留不住时改存文件。要排在 AppStores
  // 之后 —— 判定用得上它刚从加密存储迁出来的接入方式。
  final creds = await CredentialStore.open(stores.prefs);
  await tagDbReady;
  final themeInit = loadThemeSettings(stores.prefs);
  runApp(
    ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        secureStorageProvider.overrideWithValue(creds),
        themeInitProvider.overrideWithValue(themeInit),
        localTagDbProvider.overrideWithValue(tagDb),
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
  DropImportState _dropState = DropImportState.idle;

  @override
  void initState() {
    super.initState();
    _dropBridge = DropImportBridge();
    _dropBridge.attach(_openDroppedImage, onStateChanged: _setDropState);
  }

  @override
  void dispose() {
    _dropBridge.detach();
    super.dispose();
  }

  Future<void> _openDroppedImage(DroppedImage image) async {
    _setDropState(DropImportState.idle);
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

  void _setDropState(DropImportState state) {
    if (mounted && state != _dropState) setState(() => _dropState = state);
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
      navigatorObservers: [_inputFocusGuard],
      // 一层 builder 里办两件事:三键导航机上整个应用让出系统导航栏(见
      // [NavBarGuard]),以及在最上层盖拖放导入浮层(桌面端拖文件进来时)。
      builder: (context, child) => NavBarGuard(
        child: Stack(
          fit: StackFit.expand,
          children: [
            child ?? const SizedBox.shrink(),
            if (_dropState != DropImportState.idle)
              _DropImportOverlay(state: _dropState),
          ],
        ),
      ),
      home: const _AuthGate(),
    );
  }
}

class _DropImportOverlay extends StatelessWidget {
  const _DropImportOverlay({required this.state});

  final DropImportState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loading = state == DropImportState.loading;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.scrim.withValues(alpha: .18),
          border: Border.all(color: scheme.primary, width: 3),
        ),
        child: Center(
          child: Material(
            color: scheme.surface,
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: scheme.primary,
                      ),
                    )
                  else
                    Icon(
                      Icons.add_photo_alternate_outlined,
                      color: scheme.primary,
                    ),
                  const SizedBox(width: 10),
                  Text(
                    loading ? '正在读取图片…' : '松开以导入图片',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
    return const _CredentialLostHint(child: AppShell());
  }
}

/// 加密存储这次启动被系统清过(见 [CredentialStore])时,进主界面提示一次。
class _CredentialLostHint extends ConsumerStatefulWidget {
  const _CredentialLostHint({required this.child});

  final Widget child;

  @override
  ConsumerState<_CredentialLostHint> createState() =>
      _CredentialLostHintState();
}

class _CredentialLostHintState extends ConsumerState<_CredentialLostHint> {
  @override
  void initState() {
    super.initState();
    final creds = ref.read(secureStorageProvider);
    if (creds is! CredentialStore || !creds.takeLostNotice()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      hintSnack(
        context,
        '已存的 Key 被系统清掉了,重新添加后不会再丢',
        icon: Icons.key_off_outlined,
        actionLabel: '去添加',
        onAction: () {
          if (mounted) {
            Navigator.of(context).push(sharedAxisRoute(const AccountPage()));
          }
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
