// 灵感页顶栏:在线画廊是一格页签,固定垫在所有页签最右(「其他」后面),
// 不再是行尾那颗地球按钮。翻过去时新建按钮和底栏都收起来,画廊自带 API Key 入口。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/ui_prefs.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/codex/codex_favorites.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';
import 'package:plana_app/features/inspiration/codex/codex_providers.dart';
import 'package:plana_app/features/inspiration/inspiration_page.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/inspiration/widgets/category_tabs.dart';
import 'package:plana_app/features/online_gallery/online_gallery_credentials.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_page.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';

class _Library extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState();
}

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 'test', botUserId: 'me');
}

class _CodexIndex extends CodexIndexNotifier {
  @override
  Future<List<CodexMeta>> build() async => const [];
}

class _Favorites extends CodexFavoritesNotifier {
  @override
  Future<List<CodexFavorite>> build() async => const [];
}

class _Credentials extends OnlineGalleryCredentialsNotifier {
  @override
  Future<OnlineGalleryCredentials> build() async =>
      const OnlineGalleryCredentials(danbooruLogin: 'a', danbooruApiKey: 'b');
}

class _Gallery extends OnlineGalleryService {
  int requests = 0;

  @override
  Future<OnlineGalleryPageResult> fetch(
    OnlineGallerySource source, {
    required OnlineGalleryFeed feed,
    required String query,
    required int page,
    required Set<String> ratings,
    required Set<String> blacklist,
    String rankingPeriod = 'day',
    int dateDays = 0,
  }) async {
    requests++;
    return const OnlineGalleryPageResult(items: [], hasMore: false);
  }
}

void main() {
  testWidgets('在线画廊是「其他」右边的页签', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gallery = _Gallery();
    addTearDown(gallery.dispose);
    final c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        tagLibraryProvider.overrideWith(_Library.new),
        botSessionProvider.overrideWith(_Session.new),
        for (final cat in TagCategory.builtins)
          publicTagsProvider(cat).overrideWith((_) async => const []),
        tagAuthorNamesProvider.overrideWith((_) async => const {}),
        codexFavoritesProvider.overrideWith(_Favorites.new),
        codexIndexProvider.overrideWith(_CodexIndex.new),
        codexMediaProvider.overrideWith((_) async => CodexMedia.fallback),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
        onlineGalleryServiceProvider.overrideWithValue(gallery),
        onlineGalleryCredentialsProvider.overrideWith(_Credentials.new),
      ],
    );
    addTearDown(c.dispose);
    // 记好各类列数:没记过时分类页在 initState 里按屏宽算列数,debug 下会撞
    // 「initState 里查 MediaQuery」的断言(与本测试无关的老问题)
    c
        .read(uiPrefsProvider.notifier)
        .patch(
          (p) => p.copyWith(
            inspirationColumns: {
              for (final cat in TagCategory.builtins) cat.name: 3,
            },
          ),
        );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const InspirationPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final labels = tester
        .widget<CategoryTabs>(find.byType(CategoryTabs))
        .labels;
    expect(labels.last, '在线画廊');
    expect(labels[labels.length - 2], tagCategoryDef(TagCategory.other).label);
    // 行尾那颗地球按钮没了,只剩新建
    expect(find.byIcon(Icons.public), findsNothing);
    expect(find.byType(OnlineGalleryPage), findsNothing);

    await tester.tap(find.text('在线画廊'));
    await tester.pumpAndSettle();

    expect(find.byType(OnlineGalleryPage), findsOneWidget);
    // 嵌在页签里:不再套一层「在线画廊」AppBar,刷新与黑名单挪进来源那一行
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('刷新'), findsOneWidget);
    expect(find.byTooltip('黑名单'), findsOneWidget);
    // Danbooru 已填 Key:钥匙点亮
    expect(find.byTooltip('API Key(已配置)'), findsOneWidget);
    // 新建收起(不可点)
    final add = find.ancestor(
      of: find.byIcon(Icons.add),
      matching: find.byType(IgnorePointer),
    );
    expect(
      tester.widgetList<IgnorePointer>(add).any((w) => w.ignoring),
      isTrue,
    );
    expect(gallery.requests, greaterThan(0));
    expect(tester.takeException(), isNull);
    // 偏好落盘等延时任务走完再收
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });
}
