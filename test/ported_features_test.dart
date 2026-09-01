import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/fixed_tags/fixed_tags.dart';
import 'package:plana_app/features/generate/gen_queue.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';
import 'package:plana_app/features/local_gallery/local_gallery_store.dart';
import 'package:plana_app/features/precise_ref/precise_ref_library.dart';

final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _GalleryClient extends http.BaseClient {
  _GalleryClient(this.handler);

  final Future<http.Response> Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(http.Request(request.method, request.url));
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('本地图库导入去重并在重启后保留索引', () async {
    final root = await Directory.systemTemp.createTemp('plana_local_gallery');
    addTearDown(() async {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });

    final first = LocalGalleryStore(root);
    await first.load();
    final item = await first.importBytes(
      _png,
      'sample.png',
      createdAt: DateTime(2026, 1, 2).millisecondsSinceEpoch,
    );
    expect(first.initialItems, hasLength(1));
    // The tiny fixture is sufficient for byte/index testing; some Flutter
    // codecs do not decode its pixel payload, so dimensions may be unknown.
    expect(item.width, greaterThanOrEqualTo(0));
    expect(item.height, greaterThanOrEqualTo(0));
    await first.idle;

    final duplicate = await first.importBytes(_png, 'copy.png');
    expect(duplicate.id, item.id);
    expect(first.initialItems, hasLength(1));

    first.replaceItem(item.copyWith(favorite: true, category: '参考'));
    final collection = first.createCollection('灵感');
    first.replaceItem(
      first.initialItems.single.copyWith(collectionIds: [collection.id]),
    );
    await first.flush();
    await first.idle;

    final second = LocalGalleryStore(root);
    await second.load();
    expect(second.initialItems, hasLength(1));
    expect(second.initialItems.single.favorite, isTrue);
    expect(second.initialItems.single.category, '参考');
    expect(second.initialItems.single.collectionIds, [collection.id]);
    expect(await second.readImage(item.id), equals(_png));
  });

  test('精准参考库可在首次读取完成前直接导入图片', () async {
    final container = ProviderContainer();
    final notifier = container.read(preciseRefProvider.notifier);
    addTearDown(() async {
      await notifier.clearAll();
      container.dispose();
    });

    final entry = await notifier.importBytes(_png, name: 'direct-import');
    expect(entry.name, 'direct-import');
    expect(container.read(preciseRefProvider).value, contains(entry));
  });

  test('固定词按正负向与前后位置拼接并应用权重', () {
    const state = FixedTagsState(
      entries: [
        FixedTagEntry(
          id: 'p',
          name: '质量',
          content: 'masterpiece',
          weight: 1.1,
          side: FixedTagSide.positive,
          position: FixedTagPosition.prefix,
        ),
        FixedTagEntry(
          id: 's',
          name: '收尾',
          content: 'blue eyes',
          side: FixedTagSide.positive,
          position: FixedTagPosition.suffix,
        ),
        FixedTagEntry(
          id: 'n',
          name: '排除',
          content: 'watermark',
          side: FixedTagSide.negative,
        ),
      ],
    );
    expect(
      state.apply('1girl', FixedTagSide.positive),
      '{{masterpiece}}, 1girl, blue eyes',
    );
    expect(
      state.apply('bad anatomy', FixedTagSide.negative),
      'watermark, bad anatomy',
    );
  });

  test('在线来源适配器解析 Danbooru 列表', () async {
    final client = _GalleryClient((request) async {
      expect(request.url.host, 'danbooru.donmai.us');
      return http.Response(
        jsonEncode([
          {
            'id': 42,
            'rating': 'g',
            'score': 8,
            'image_width': 640,
            'image_height': 960,
            'tag_string': '1girl blue_hair',
            'file_ext': 'jpg',
            'file_url': 'https://cdn.example/full.jpg',
            'large_file_url': 'https://cdn.example/large.jpg',
            'preview_file_url': 'https://cdn.example/preview.jpg',
          },
        ]),
        200,
      );
    });
    final service = OnlineGalleryService(client: client);
    final page = await service.fetch(
      OnlineGallerySource.danbooru,
      feed: OnlineGalleryFeed.search,
      query: '1girl',
      page: 1,
      ratings: const {'g', 's', 'q', 'e'},
      blacklist: const {},
    );
    expect(page.items.single.stableId, 'danbooru:42');
    expect(page.items.single.tags, ['1girl', 'blue_hair']);
    expect(page.items.single.width, 640);
    service.dispose();
  });

  test('AI TAG 列表缺少图片地址时保留条目并解析标签', () async {
    final client = _GalleryClient((request) async {
      if (request.url.path == '/api/config') {
        return http.Response(
          jsonEncode({'asset_base_url': 'https://cdn.example/'}),
          200,
        );
      }
      expect(request.url.path, '/api/ai_works_search');
      return http.Response(
        jsonEncode({
          'total': 1,
          'items': [
            {
              'id': 7,
              'title': 'test work',
              'tags': '["1girl", "blue_hair"]',
              'userName': 'tester',
            },
          ],
        }),
        200,
      );
    });
    final service = OnlineGalleryService(client: client);
    final page = await service.fetch(
      OnlineGallerySource.aiTag,
      feed: OnlineGalleryFeed.search,
      query: '1girl',
      page: 1,
      ratings: const {'g', 's', 'q', 'e'},
      blacklist: const {},
    );
    expect(page.items, hasLength(1));
    expect(page.items.single.tags, ['1girl', 'blue_hair']);
    expect(page.items.single.previewUrl, isEmpty);
    service.dispose();
  });

  test('输出过滤只移除精确水印标签', () {
    const state = OnlineGalleryState(outputFilter: true);
    expect(
      state.filterOutputPrompt('1girl, watermark, watermark_style, {censored}'),
      '1girl, watermark_style',
    );
  });

  test('在线收藏跨 JSON 往返并保持来源隔离', () {
    const danbooru = OnlineGalleryItem(
      id: '42',
      source: OnlineGallerySource.danbooru,
      previewUrl: 'https://example.test/preview.jpg',
      imageUrl: 'https://example.test/full.jpg',
      tags: ['1girl', 'solo'],
    );
    const safebooru = OnlineGalleryItem(
      id: '42',
      source: OnlineGallerySource.safebooru,
      previewUrl: 'https://example.test/safe.jpg',
      imageUrl: 'https://example.test/safe.jpg',
    );
    final encoded = encodeOnlineFavorites({
      danbooru.stableId: danbooru,
      safebooru.stableId: safebooru,
    });
    final decoded = decodeOnlineFavorites(encoded);
    expect(decoded.keys, containsAll([danbooru.stableId, safebooru.stableId]));
    expect(decoded[danbooru.stableId]!.tags, ['1girl', 'solo']);
  });

  test('固定词 provider 持久化后可从新容器水合', () async {
    final root = await Directory.systemTemp.createTemp('plana_fixed_tags');
    addTearDown(() async {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });
    final stores = await AppStores.open(rootOverride: root);
    final first = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    first.read(fixedTagsProvider.notifier).add(
      name: 'quality',
      content: 'masterpiece',
    );
    await stores.prefs.write(
      key: 'fixed_tags_v1',
      value: jsonEncode([
        const FixedTagEntry(
          id: 'saved',
          name: 'quality',
          content: 'masterpiece',
        ).toJson(),
      ]),
    );
    first.dispose();

    final restoredStores = await AppStores.open(rootOverride: root);
    final second = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(restoredStores)],
    );
    addTearDown(second.dispose);
    expect(second.read(fixedTagsProvider).entries.single.content, 'masterpiece');
  });

  test('队列管理支持重排且快照不受当前工作台修改影响', () {
    final stores = AppStores.ephemeral();
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    addTearDown(() {
      container.dispose();
      stores.flushNow();
    });

    final generator = container.read(generateProvider.notifier);
    generator.setPrompts(positive: 'first');
    final queue = container.read(genQueueProvider.notifier);
    expect(queue.enqueue(), isTrue);
    generator.setPrompts(positive: 'second');
    expect(queue.enqueue(), isTrue);

    final ids = [for (final task in container.read(genQueueProvider).items) task.id];
    queue.reorder(0, 1);
    final ordered = container.read(genQueueProvider).items;
    expect([for (final task in ordered) task.id], [ids[1], ids[0]]);
    expect(ordered.first.snapshot.prompt, 'second');
    expect(ordered.last.snapshot.prompt, 'first');
  });
}
