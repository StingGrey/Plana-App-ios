import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';
import 'package:plana_app/features/online_gallery/online_gallery_import_sheet.dart';

void main() {
  const item = OnlineGalleryItem(
    id: '1',
    source: OnlineGallerySource.danbooru,
    previewUrl: 'https://example.com/1.jpg',
    imageUrl: '',
    tags: ['artist_name', '1girl', 'highres'],
    tagCategories: {
      'artist_name': OnlineGalleryTagCategory.artist,
      '1girl': OnlineGalleryTagCategory.general,
      'highres': OnlineGalleryTagCategory.meta,
    },
    negativePrompt: 'low quality',
  );
  test(
    'Danbooru categories survive detail, copy and favorite persistence',
    () async {
      final service = OnlineGalleryService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'id': 1,
              'file_url': item.previewUrl,
              'tag_string': 'artist_name series character 1girl highres',
              'tag_string_artist': 'artist_name',
              'tag_string_copyright': 'series',
              'tag_string_character': 'character',
              'tag_string_general': '1girl',
              'tag_string_meta': 'highres',
            }),
            200,
          ),
        ),
      );
      addTearDown(service.dispose);
      final parsed = (await service.detail(item)).item.copyWith(score: 10);
      final restored = decodeOnlineFavorites(
        encodeOnlineFavorites({parsed.stableId: parsed}),
      ).values.single;
      expect(restored.groupedTags.keys, [
        OnlineGalleryTagCategory.artist,
        OnlineGalleryTagCategory.copyright,
        OnlineGalleryTagCategory.character,
        OnlineGalleryTagCategory.general,
        OnlineGalleryTagCategory.meta,
      ]);
      expect(restored.tagCategories['highres'], OnlineGalleryTagCategory.meta);
      final old = item.toJson()..remove('tagCategories');
      expect(OnlineGalleryItem.fromJson(old)!.groupedTags.keys, [
        OnlineGalleryTagCategory.unknown,
      ]);
    },
  );
  test(
    'Gelbooru extracts categories from sidebar without importing links or counts',
    () async {
      final service = OnlineGalleryService(
        client: MockClient(
          (_) async => http.Response('''
      <section class="image-container" data-tags="artist_name 1girl highres"></section>
      <li class="tag-type-artist"><a href="?page=wiki">?</a><a href="?page=post&amp;s=list&amp;tags=artist_name">artist name</a> 100</li>
      <li class="tag-type-general"><a href="?page=post&amp;s=list&amp;tags=1girl">1girl</a> 100</li>
      <li class="tag-type-metadata"><a href="?page=post&amp;s=list&amp;tags=highres">highres</a> 100</li>
    ''', 200),
        ),
      );
      addTearDown(service.dispose);
      final parsed = (await service.detail(
        OnlineGalleryItem(
          id: '1',
          source: OnlineGallerySource.gelbooru,
          previewUrl: item.previewUrl,
          imageUrl: '',
        ),
      )).item;
      expect(parsed.tagCategories, item.tagCategories);
      expect(parsed.tags, item.tags);
    },
  );
  testWidgets(
    'Import selects categories and individual tags, cancel and empty are safe',
    (tester) async {
      GalleryPromptImport? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<GalleryPromptImport>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        OnlineGalleryImportSheet(item: item, filter: (s) => s),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '导入生图'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('通用 · General (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入生图'));
      await tester.pumpAndSettle();
      expect(result!.positive, '1girl');
      expect(result!.negative, isNull);
      result = null;
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );
}
