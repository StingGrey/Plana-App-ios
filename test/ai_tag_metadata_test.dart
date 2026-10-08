import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/online_gallery/ai_tag_metadata.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';
import 'package:plana_app/features/online_gallery/online_gallery_import_sheet.dart';

const _lora = '<lora:[Style] Tian Zhu2357 [Illustrious-XL]:0.8>';
OnlineGalleryItem _item(
  String platform, {
  String prompt = '',
  String negative = '',
}) => OnlineGalleryItem(
  id: platform,
  source: OnlineGallerySource.aiTag,
  previewUrl: 'https://example.com/a.jpg',
  imageUrl: '',
  platform: platform,
  tags: const ['作品标签'],
  prompt: prompt,
  negativePrompt: negative,
);
void main() {
  test('NAI Comment prompt and uc override truncated prompt_text', () {
    final p = parseAiTagPrompts({
      'prompt_text': 'truncated',
      'ai_json': jsonEncode({
        'Description': 'fallback',
        'Comment': jsonEncode({
          'prompt': 'masterpiece, soft lighting, red blanket',
          'uc': 'lowres, film grain',
        }),
      }),
    });
    expect(p.positive, 'masterpiece, soft lighting, red blanket');
    expect(p.negative, 'lowres, film grain');
    expect(p.negativeSource, 'uc');
  });
  test('V4 base and character captions stay in their respective sides', () {
    final p = parseAiTagPrompts({
      'ai_json': {
        'Comment': {
          'prompt': 'base',
          'uc': 'negative',
          'v4_prompt': {
            'caption': {
              'base_caption': 'base',
              'char_captions': [
                {'char_caption': 'blue eyes'},
              ],
            },
          },
          'v4_negative_prompt': {
            'caption': {
              'base_caption': 'negative',
              'char_captions': [
                {'char_caption': 'red eyes'},
              ],
            },
          },
        },
      },
    });
    expect(p.positive, 'base, blue eyes');
    expect(p.negative, 'negative, red eyes');
  });
  test(
    'SD parameters separate negative text and strip settings, retaining LoRA for optional filtering',
    () {
      final p = parseAiTagPrompts({
        'ai_json': {
          'parameters':
              'soft lighting, $_lora\nNegative prompt: lowres\nSteps: 30, Sampler: Euler, Seed: 123',
        },
      });
      expect(p.positive, 'soft lighting, $_lora');
      expect(p.negative, 'lowres');
    },
  );
  test('ComfyUI API graph traces conditioning, not filenames or notes', () {
    final p = parseAiTagPrompts({
      'ai_json': {
        'prompt': jsonEncode({
          '1': {
            'class_type': 'CLIPTextEncode',
            'inputs': {'text': 'natural light'},
          },
          '2': {
            'class_type': 'CLIPTextEncode',
            'inputs': {'text': 'lowres'},
          },
          '3': {
            'class_type': 'KSampler',
            'inputs': {
              'positive': ['1', 0],
              'negative': ['2', 0],
            },
          },
          '4': {
            'class_type': 'Note',
            'inputs': {'text': 'not a prompt'},
          },
        }),
      },
    });
    expect(p.positive, 'natural light');
    expect(p.negative, 'lowres');
  });
  test('ComfyUI workflow links separate positive and negative nodes', () {
    final p = parseAiTagPrompts({
      'ai_json': {
        'nodes': [
          {
            'id': 1,
            'type': 'CLIPTextEncode',
            'widgets_values': ['soft light'],
          },
          {
            'id': 2,
            'type': 'CLIPTextEncode',
            'widgets_values': ['lowres'],
          },
          {
            'id': 3,
            'type': 'KSampler',
            'inputs': [
              {'name': 'positive', 'link': 10},
              {'name': 'negative', 'link': 11},
            ],
          },
        ],
        'links': [
          [10, 1, 0, 3, 0, 'CONDITIONING'],
          [11, 2, 0, 3, 1, 'CONDITIONING'],
        ],
      },
    });
    expect(p.positive, 'soft light');
    expect(p.negative, 'lowres');
  });
  test(
    'unknown workflows do not leak raw JSON or publication tags into generation',
    () {
      final p = parseAiTagPrompts({
        'ai_json': {
          'nodes': [
            {
              'type': 'Unknown',
              'widgets_values': ['filename.png'],
            },
          ],
        },
      });
      expect(p.positive, isEmpty);
      expect(_item('ComfyUI').importTags, isEmpty);
    },
  );
  test(
    'LoRA filter handles embedded and consecutive model tags without losing nearby text',
    () {
      expect(
        removeExtraNetworkTags('1girl, $_lora, natural light'),
        '1girl, natural light',
      );
      expect(
        removeExtraNetworkTags('$_lora<LYCO:another:1>blue eyes'),
        'blue eyes',
      );
      expect(
        removeExtraNetworkTags('hyperrealistic, lora style, <ordinary>'),
        'hyperrealistic, lora style, <ordinary>',
      );
      expect(removeExtraNetworkTags(_lora), isEmpty);
      expect(
        splitGalleryPrompt(
          'soft lighting, (red dress:1.2), 1.3::blue sky, clouds::, $_lora',
        ),
        ['soft lighting', '(red dress:1.2)', '1.3::blue sky, clouds::', _lora],
      );
    },
  );
  test(
    'platform filtering preserves source data, favorites and unknown labels',
    () {
      final items = [_item('NAI'), _item('SD'), _item('ComfyUI'), _item('未知')];
      final state = OnlineGalleryState(
        items: items,
        excludedPlatforms: {'SD', 'ComfyUI'},
      );
      expect(state.displayItems.map((i) => i.platform), ['NAI', '未知']);
      expect(state.items.length, 4);
      final restored = decodeOnlineFavorites(
        encodeOnlineFavorites({for (final i in items) i.stableId: i}),
      );
      expect(restored.values.map((i) => i.platform), [
        'NAI',
        'SD',
        'ComfyUI',
        '未知',
      ]);
      expect(aiPlatform('novelai'), 'NAI');
      expect(aiPlatform(''), '未知');
    },
  );
  test(
    'platform exclusions persist across notifier recreation without touching credentials',
    () async {
      final stores = AppStores.ephemeral();
      final service = OnlineGalleryService(
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      addTearDown(service.dispose);
      ProviderContainer scope() => ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          onlineGalleryServiceProvider.overrideWithValue(service),
        ],
      );
      final first = scope();
      first.read(onlineGalleryProvider.notifier).setExcludedPlatforms({'SD'});
      await Future<void>.delayed(Duration.zero);
      first.dispose();
      final second = scope();
      addTearDown(second.dispose);
      expect(second.read(onlineGalleryProvider).excludedPlatforms, {'SD'});
      await Future<void>.delayed(Duration.zero);
    },
  );
  test('detail sorts images and reads each image prompt and platform', () async {
    final service = OnlineGalleryService(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path == '/api/config'
                ? {'asset_base_url': 'https://example.com/'}
                : {
                    'work': {'AI_type': 'NAI'},
                    'images': [
                      {
                        'file_name': 'work_p1.webp',
                        'image_path': 'p1.webp',
                        'image_type': 'SD',
                        'ai_json': {
                          'parameters':
                              'second\nNegative prompt: blurry\nSteps: 20, Seed: 2',
                        },
                      },
                      {
                        'file_name': 'work_p0.webp',
                        'image_path': 'p0.webp',
                        'ai_json': {
                          'Comment': {'prompt': 'first', 'uc': 'lowres'},
                        },
                      },
                    ],
                  },
          ),
          200,
        ),
      ),
    );
    addTearDown(service.dispose);
    final result = await service.detail(_item('未知'));
    expect(result.images.map((i) => i.prompt), ['first', 'second']);
    expect(result.images.map((i) => i.platform), ['NAI', 'SD']);
    expect(result.item.negativePrompt, 'lowres');
  });
  testWidgets(
    'AI import uses actual prompt tokens and filters both sides with an opt-out',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      GalleryPromptImport? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('open'),
                onPressed: () async {
                  result = await showModalBottomSheet<GalleryPromptImport>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => OnlineGalleryImportSheet(
                      item: _item(
                        'SD',
                        prompt: 'soft lighting, $_lora',
                        negative: 'lowres, $_lora',
                      ),
                      filter: (s) => s,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按标签选择'));
      await tester.pumpAndSettle();
      expect(find.text('作品标签'), findsNothing);
      expect(find.widgetWithText(FilterChip, 'soft lighting'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('负向提示词'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('负向提示词'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == 'lowres',
        ),
        150,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == 'lowres, $_lora',
        ),
        150,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入生图'));
      await tester.pumpAndSettle();
      expect(result!.positive, 'soft lighting');
      expect(result!.negative, 'lowres');
    },
  );
}
