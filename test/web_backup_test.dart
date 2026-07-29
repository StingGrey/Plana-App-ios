// web「数据备份」文件 → app 侧形状的解析与适配。
// 契约以 web src/services/backupService.ts + utils/storage.ts 为准。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/migrate/web_backup.dart';
import 'package:plana_app/features/vibe_library/naiv4vibe_codec.dart';

/// 1×1 PNG 的 base64(拿来当图字节,内容不重要,能解码就行)。
const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGMAAQAABQAB'
    'oIJXOQAAAABJRU5ErkJggg==';

Map<String, dynamic> _backupMap({
  List<Map<String, dynamic>> vibes = const [],
  List<Map<String, dynamic>> crs = const [],
  List<Map<String, dynamic>> artists = const [],
  List<Map<String, dynamic>> ocs = const [],
  Map<String, String> localStorage = const {},
  Object? identifier = kWebBackupIdentifier,
  Object? version = kWebBackupVersion,
}) => {
  'meta': {
    'identifier': identifier,
    'version': version,
    'createdAt': '2026-07-29T10:00:00.000Z',
    'createdAtTimestamp': 1785060000000,
  },
  'localStorage': localStorage,
  'indexedDB': {
    'vibes': vibes,
    'oc_files': ocs,
    'artist_files': artists,
    'cr_files': crs,
  },
};

String _json(Map<String, dynamic> m) => jsonEncode(m);

void main() {
  group('文件校验', () {
    test('标识不匹配 → 拒绝', () {
      expect(
        () => WebBackup.parse(_json(_backupMap(identifier: 'something-else'))),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('标识'),
          ),
        ),
      );
    });

    test('版本不支持 → 拒绝(消息带上版本号)', () {
      expect(
        () => WebBackup.parse(_json(_backupMap(version: 99))),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('99'),
          ),
        ),
      );
    });

    test('不是 JSON / 结构不完整 → 拒绝', () {
      expect(() => WebBackup.parse('不是 json'), throwsFormatException);
      expect(
        () => WebBackup.parse(
          jsonEncode({
            'meta': {
              'identifier': kWebBackupIdentifier,
              'version': kWebBackupVersion,
            },
          }),
        ),
        throwsFormatException,
      );
    });
  });

  group('Vibe 适配', () {
    final vibeData = {
      'id': 'abc123',
      'name': '测试 vibe',
      'size': '1.2 MB',
      'preview': 'data:image/jpeg;base64,$_png1x1', // VibeData 叫 preview
      'image': _png1x1,
      'encodings': {
        'v4-5full': {
          'hashkey1': {
            'encoding': 'ENCODED_STRING',
            'params': {'information_extracted': 1.0},
          },
        },
      },
      'createdAt': 1700000000000,
      'defaultStrength': 0.6,
      'defaultInfoExtracted': 0.8,
      'tags': ['风景', '夜'],
      // 以下是 web 云同步私有账本,不该带进 app
      'cloudSync': 'synced',
      'cloudFilename': 'x.naiv4vibe',
      'localMetaFp': 'deadbeef',
    };

    test('转出的包能被 app 自己的 vibe 解析器吃下(往返)', () {
      final b = WebBackup.parse(_json(_backupMap(vibes: [vibeData])));
      final bundle = b.vibeBundleText();
      expect(bundle, isNotNull);

      // 关键:走 app 线上导入实际用的那个解析器,不是测试里另写一套
      final parsed = parseVibeFileText(bundle!);
      expect(parsed, hasLength(1));
      final p = parsed.single;
      expect(p.id, 'abc123');
      expect(p.name, '测试 vibe');
      expect(p.imageBase64, _png1x1);
      expect(p.tags, ['风景', '夜']);
      expect(p.createdAt, 1700000000000);
    });

    test('preview → thumbnail(两边字段名不同,搬错就没缩略图)', () {
      final b = WebBackup.parse(_json(_backupMap(vibes: [vibeData])));
      final p = parseVibeFileText(b.vibeBundleText()!).single;
      expect(p.thumbnailDataUrl, startsWith('data:image/jpeg;base64,'));
    });

    test('默认参数被收进 importInfo(拍平字段直接搬会丢默认值)', () {
      final b = WebBackup.parse(_json(_backupMap(vibes: [vibeData])));
      final p = parseVibeFileText(b.vibeBundleText()!).single;
      expect(p.defaultStrength, 0.6);
      expect(p.defaultInfoExtracted, 0.8);
    });

    test('encodings 原样透传,导入即免重新编码', () {
      final b = WebBackup.parse(_json(_backupMap(vibes: [vibeData])));
      final p = parseVibeFileText(b.vibeBundleText()!).single;
      expect(p.supportedModelKeys, ['v4-5full']);
      final items = p.encodingItems;
      expect(items, hasLength(1));
      expect(items.single.modelKey, 'v4-5full');
      expect(items.single.encoding, 'ENCODED_STRING');
      expect(items.single.infoExtracted, 1.0);
    });

    test('web 云同步字段不带进 app', () {
      final raw = vibeDataToNaiv4(vibeData);
      expect(raw.containsKey('cloudSync'), isFalse);
      expect(raw.containsKey('cloudFilename'), isFalse);
      expect(raw.containsKey('localMetaFp'), isFalse);
    });

    test('无默认参数时不产出空的 importInfo', () {
      final raw = vibeDataToNaiv4({'id': 'x', 'name': 'n', 'image': _png1x1});
      expect(raw.containsKey('importInfo'), isFalse);
    });

    test('没有 vibe 时 bundle 为 null', () {
      expect(WebBackup.parse(_json(_backupMap())).vibeBundleText(), isNull);
    });
  });

  group('角色参考适配', () {
    test('preview 的 data URL 解成字节', () {
      final b = WebBackup.parse(
        _json(
          _backupMap(
            crs: [
              {
                'id': 'cr1',
                'name': '小明',
                'preview': 'data:image/png;base64,$_png1x1',
                'isLocal': true,
                'createdAt': 1700000000000,
              },
            ],
          ),
        ),
      );
      expect(b.crs, hasLength(1));
      expect(b.crs.single.name, '小明');
      expect(b.crs.single.bytes, isNotEmpty);
    });

    test('解不出图的条目丢弃(留着也没有可落库的内容)', () {
      final b = WebBackup.parse(
        _json(
          _backupMap(
            crs: [
              {'id': 'a', 'name': '无图', 'preview': ''},
              {'id': 'b', 'name': '坏串', 'preview': 'data:image/png;base64,!!!'},
            ],
          ),
        ),
      );
      expect(b.crs, isEmpty);
    });

    test('无名条目落到兜底名', () {
      final b = WebBackup.parse(
        _json(
          _backupMap(
            crs: [
              {'id': 'a', 'preview': 'data:image/png;base64,$_png1x1'},
            ],
          ),
        ),
      );
      expect(b.crs.single.name, '参考图');
    });
  });

  group('预设适配', () {
    test('内置三档剔除,自定义保留,激活 id 读出', () {
      final b = WebBackup.parse(
        _json(
          _backupMap(
            localStorage: {
              'novelai_prompt_presets': jsonEncode([
                {
                  'id': 'heavy',
                  'name': '重度',
                  'positive': 'x',
                  'negative': 'y',
                  'isDefault': true,
                },
                {
                  'id': 'custom_1',
                  'name': '我的',
                  'positive': 'a',
                  'negative': 'b',
                  'createdAt': 1700000000000,
                },
              ]),
              'novelai_active_preset': 'custom_1',
            },
          ),
        ),
      );
      expect(b.presets, hasLength(1));
      expect(b.presets.single.id, 'custom_1');
      expect(b.presets.single.name, '我的');
      expect(b.presets.single.positive, 'a');
      expect(b.activePresetId, 'custom_1');
    });

    test('内置 id 即使没标 isDefault 也不覆盖内置文本', () {
      final b = WebBackup.parse(
        _json(
          _backupMap(
            localStorage: {
              'novelai_prompt_presets': jsonEncode([
                {'id': 'light', 'name': '冒名', 'positive': '', 'negative': ''},
              ]),
            },
          ),
        ),
      );
      expect(b.presets, isEmpty);
    });

    test('预设 JSON 坏了不连累整个备份', () {
      final b = WebBackup.parse(
        _json(
          _backupMap(
            vibes: [
              {'id': 'v', 'name': 'v', 'image': _png1x1},
            ],
            localStorage: {'novelai_prompt_presets': '{坏掉的 json'},
          ),
        ),
      );
      expect(b.presets, isEmpty);
      expect(b.vibes, hasLength(1)); // vibe 照常
    });
  });

  group('画师串 / OC → 灵感库', () {
    final backup = WebBackup.parse(
      _json(
        _backupMap(
          artists: [
            // web ArtistData:提示词在 prompt,预览是数组
            {
              'id': 'a1',
              'name': 'A1',
              'prompt': 'artist:wlop',
              'negative': 'bad',
              'previews': ['https://x/1.png'],
              'isLocal': true,
              'createdAt': 1700000000000,
            },
          ],
          ocs: [
            // web OCData:提示词在 positive,预览是单个 data URL
            {
              'id': 'o1',
              'name': '小红',
              'positive': 'red hair',
              'negative': '',
              'aliases': ['xiaohong'],
              'preview': 'data:image/png;base64,$_png1x1',
              'user': 'someone',
              'isLocal': true,
              'createdAt': 1700000000000,
            },
          ],
        ),
      ),
    );

    test('按灵感库 webId 分类装箱(character / artist-style)', () {
      final cats = backup.tagCategories();
      expect(cats.keys, containsAll(['character', 'artist-style']));
      expect(cats['character'], hasLength(1));
      expect(cats['artist-style'], hasLength(1));
    });

    test('原始 map 原样带过去,由灵感库自己的解码器处理', () {
      // 画师串的提示词在 prompt、OC 的在 positive —— 两种 shape 都不在这层动
      expect(backup.artists.single['prompt'], 'artist:wlop');
      expect(backup.ocs.single['positive'], 'red hair');
    });

    test('灵感库解码器能吃下这两种 shape(与线上导入同一个函数)', () {
      final artist = decodeBackupEntry(TagCategory.artist, backup.artists.single);
      expect(artist, isNotNull);
      expect(artist!.name, 'A1');
      expect(artist.positive, 'artist:wlop'); // prompt → positive
      expect(artist.negative, 'bad');
      expect(artist.previews, ['https://x/1.png']);

      final oc = decodeBackupEntry(TagCategory.character, backup.ocs.single);
      expect(oc, isNotNull);
      expect(oc!.name, '小红');
      expect(oc.positive, 'red hair');
      expect(oc.aliases, ['xiaohong']);
      expect(oc.createdBy, 'someone');
      // base64 内嵌预览体积过大,灵感库有意不落地
      expect(oc.previews, isEmpty);
    });

    test('没有这两类时不产出空分类', () {
      expect(WebBackup.parse(_json(_backupMap())).tagCategories(), isEmpty);
    });
  });

  test('空备份判定', () {
    expect(WebBackup.parse(_json(_backupMap())).isEmpty, isTrue);
    for (final b in [
      _backupMap(
        vibes: [
          {'id': 'v', 'name': 'v', 'image': _png1x1},
        ],
      ),
      _backupMap(
        artists: [
          {'id': 'a', 'name': 'a'},
        ],
      ),
      _backupMap(
        ocs: [
          {'id': 'o', 'name': 'o'},
        ],
      ),
    ]) {
      expect(WebBackup.parse(_json(b)).isEmpty, isFalse);
    }
  });
}
