import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/backend_config.dart';
import '../../core/theme/app_theme.dart';
import '../gallery/gallery_page.dart';
import '../gallery/gallery_state.dart';
import '../generate/generate_page.dart';
import '../generate/generation_controller.dart';
import '../inpaint/inpaint_overlay.dart';
import '../profile/profile_page.dart';
import 'shell_state.dart';

/// 全局骨架:3 tab 底部导航 + PageView 左右滑动切页(手势滑 + 点按/程序跳转都走同一索引)。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final PageController _pc = PageController(
    initialPage: ref.read(shellIndexProvider),
  );

  static const _pages = [GeneratePage(), GalleryPage(), ProfilePage()];

  @override
  void initState() {
    super.initState();
    // 预热鉴权/后端配置(懒加载 AsyncNotifier 的 storage 首读在此触发,
    // 否则冷启动后立刻点「生成」会在 loading 态被误判成未授权/没 token)。
    ref.read(tokenProvider);
    ref.read(botSessionProvider);
    ref.read(backendBaseProvider);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellIndexProvider);
    // 图库 tab 上重绘编辑中 / 大图缩放中:锁 PageView 横滑
    // (防抢涂抹与拖动手势);其他 tab 横滑自由。
    final lockSwipe =
        (ref.watch(inpaintSessionProvider) != null ||
            ref.watch(galleryZoomedProvider)) &&
        index == 1;

    // 索引变化(导航点按 / 生成后跳图库)→ 滑到对应页(手势滑动来的已就位,跳过)。
    ref.listen<int>(shellIndexProvider, (prev, next) {
      if (!_pc.hasClients) return;
      final current = _pc.page?.round() ?? _pc.initialPage;
      if (current != next) {
        _pc.animateToPage(
          next,
          duration: Motion.medium,
          curve: Motion.emphasized,
        );
      }
    });

    // 生成错误全局提示(常驻:切 tab 也不漏)
    ref.listen<GenStatus>(generationProvider, (prev, next) {
      final err = next.error;
      if (err == null) return;
      final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
      if (next.noToken) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text('请先在「我的」页设置 NovelAI API Token'),
            action: SnackBarAction(
              label: '去设置',
              onPressed: () => ref.read(shellIndexProvider.notifier).select(2),
            ),
          ),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text(err)));
      }
      ref.read(generationProvider.notifier).clearError();
    });

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: PageView(
          controller: _pc,
          physics: lockSwipe ? const NeverScrollableScrollPhysics() : null,
          onPageChanged: (i) => ref.read(shellIndexProvider.notifier).select(i),
          children: _pages,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        // 重绘编辑中也允许点按切页(图库页 keep-alive,回来面板还在);
        // 仅横滑仍锁(防抢涂抹手势)。
        onDestinationSelected: (i) =>
            ref.read(shellIndexProvider.notifier).select(i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.draw_outlined),
            selectedIcon: Icon(Icons.draw),
            label: '创作',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            selectedIcon: Icon(Icons.photo_library),
            label: '图库',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
