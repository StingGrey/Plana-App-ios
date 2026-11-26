import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/online_gallery/online_gallery_credentials.dart';
import 'package:plana_app/features/online_gallery/online_gallery_models.dart';
import 'package:plana_app/features/online_gallery/online_gallery_service.dart';

const _all = {'g', 's', 'q', 'e'};

Future<OnlineGalleryPageResult> _fetch(
  OnlineGalleryService service,
  OnlineGallerySource source, {
  String query = '',
  int page = 1,
}) => service.fetch(
  source,
  feed: OnlineGalleryFeed.search,
  query: query,
  page: page,
  ratings: _all,
  blacklist: const {},
);

void main() {
  group('凭据模型', () {
    test('半填不算配置;JSON 来回不丢', () {
      const c = OnlineGalleryCredentials(
        danbooruLogin: 'alice',
        gelbooruUserId: '42',
        gelbooruApiKey: 'k',
      );
      expect(c.hasDanbooru, isFalse);
      expect(c.configuredFor(OnlineGallerySource.safebooru), isFalse);
      expect(c.configuredFor(OnlineGallerySource.gelbooru), isTrue);
      expect(c.configuredFor(OnlineGallerySource.codex), isFalse);
      final back = OnlineGalleryCredentials.fromJson(
        jsonDecode(jsonEncode(c.toJson())),
      );
      expect(back, c);
      expect(const OnlineGalleryCredentials().isEmpty, isTrue);
    });

    test('Gelbooru 账户页整串能拆出 User ID 和 Key', () {
      final parsed = parseGelbooruCredentialString(
        '&api_key=abcDEF0123456789&user_id=123456',
      );
      expect(parsed?.userId, '123456');
      expect(parsed?.apiKey, 'abcDEF0123456789');
      expect(parseGelbooruCredentialString('abcDEF0123456789'), isNull);
    });

    test('Gelbooru 日期按时区换成 UTC', () {
      expect(
        parseGelbooruDate('Sat Nov 23 18:09:31 -0500 2024'),
        DateTime.utc(2024, 11, 23, 23, 9, 31),
      );
      expect(
        parseGelbooruDate('Mon Jan 01 08:00:00 +0900 2024'),
        DateTime.utc(2023, 12, 31, 23),
      );
      expect(parseGelbooruDate(''), isNull);
    });
  });

  group('请求带凭据', () {
    test('Danbooru 接口带 Basic,图片 CDN 不带', () async {
      final seen = <http.Request>[];
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          seen.add(req);
          if (req.url.host == 'cdn.donmai.us') {
            return http.Response.bytes(
              [1, 2, 3],
              200,
              headers: {'content-type': 'image/png'},
            );
          }
          return http.Response('[]', 200);
        }),
        credentials: () async => const OnlineGalleryCredentials(
          danbooruLogin: 'alice',
          danbooruApiKey: 'secret',
        ),
      );
      addTearDown(service.dispose);
      await _fetch(service, OnlineGallerySource.danbooru);
      await _fetch(service, OnlineGallerySource.safebooru);
      await service.download('https://cdn.donmai.us/original/a.png');
      final basic = 'Basic ${base64Encode(utf8.encode('alice:secret'))}';
      expect(seen[0].url.host, 'danbooru.donmai.us');
      expect(seen[0].headers['Authorization'], basic);
      expect(seen[1].url.host, 'safebooru.donmai.us');
      expect(seen[1].headers['Authorization'], basic);
      expect(seen[2].headers.containsKey('Authorization'), isFalse);
      // 凭据不进网址
      expect(seen[0].url.toString(), isNot(contains('secret')));
    });

    test('没填凭据时匿名访问', () async {
      final seen = <http.Request>[];
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          seen.add(req);
          return http.Response('[]', 200);
        }),
      );
      addTearDown(service.dispose);
      await _fetch(service, OnlineGallerySource.danbooru);
      expect(seen.single.headers.containsKey('Authorization'), isFalse);
    });

    test('Key 被拒时提示 Key 无效,而不是笼统的请求失败', () async {
      final service = OnlineGalleryService(
        client: MockClient((_) async => http.Response('{}', 401)),
        credentials: () async => const OnlineGalleryCredentials(
          danbooruLogin: 'alice',
          danbooruApiKey: 'wrong',
        ),
      );
      addTearDown(service.dispose);
      expect(
        () => _fetch(service, OnlineGallerySource.danbooru),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('API Key 无效'),
          ),
        ),
      );
    });

    test('Gelbooru 填了 Key 走 DAPI,解析原图、尺寸、分级与日期', () async {
      final seen = <Uri>[];
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          seen.add(req.url);
          return http.Response(
            jsonEncode({
              '@attributes': {'limit': 42, 'offset': 42, 'count': 100},
              'post': [
                {
                  'id': 777,
                  'created_at': 'Sat Nov 23 18:09:31 -0500 2024',
                  'score': 12,
                  'width': 1200,
                  'height': 1800,
                  'rating': 'sensitive',
                  'tags': '1girl solo rating:sensitive it&#039;s_ok',
                  'file_url': 'https://img3.gelbooru.com/images/aa/bb/x.png',
                  'sample_url':
                      'https://img3.gelbooru.com/samples/aa/bb/sample_x.jpg',
                  'preview_url':
                      'https://img3.gelbooru.com/thumbnails/aa/bb/thumbnail_x.jpg',
                  'owner': 'bob',
                  'source': 'https://example.com/src',
                },
                {
                  'id': 778,
                  'width': 640,
                  'height': 360,
                  'rating': 'general',
                  'tags': '1girl animated video',
                  'file_url': 'https://img3.gelbooru.com/images/aa/bb/v.mp4',
                  'sample_url': '',
                  'preview_url':
                      'https://img3.gelbooru.com/thumbnails/aa/bb/thumbnail_v.jpg',
                },
              ],
            }),
            200,
          );
        }),
        credentials: () async => const OnlineGalleryCredentials(
          gelbooruUserId: '123',
          gelbooruApiKey: 'gk',
        ),
      );
      addTearDown(service.dispose);
      final result = await _fetch(
        service,
        OnlineGallerySource.gelbooru,
        query: '1girl',
        page: 2,
      );
      final q = seen.single.queryParameters;
      expect(q['page'], 'dapi');
      expect(q['json'], '1');
      expect(q['pid'], '1', reason: 'DAPI 的 pid 是页码,不是偏移');
      expect(q['tags'], '1girl');
      expect(q['api_key'], 'gk');
      expect(q['user_id'], '123');

      final image = result.items.first;
      expect(image.id, '777');
      expect(image.imageUrl, endsWith('/images/aa/bb/x.png'));
      expect(image.previewUrl, endsWith('/samples/aa/bb/sample_x.jpg'));
      expect(image.width, 1200);
      expect(image.rating, 's');
      expect(image.author, 'bob');
      expect(image.tags, ['1girl', 'solo', "it's_ok"]);
      expect(image.createdAt, DateTime.utc(2024, 11, 23, 23, 9, 31));
      expect(image.fileExtension, 'png');

      final video = result.items.last;
      expect(video.previewUrl, endsWith('thumbnail_v.jpg'), reason: '视频卡片用缩略图');
      expect(result.hasMore, isTrue, reason: '2 × 42 < 100');
    });

    test('Gelbooru 没填 Key 照旧抓 HTML 列表', () async {
      final seen = <Uri>[];
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          seen.add(req.url);
          return http.Response('<html></html>', 200);
        }),
      );
      addTearDown(service.dispose);
      await _fetch(service, OnlineGallerySource.gelbooru);
      expect(seen.single.queryParameters['s'], 'list');
      expect(seen.single.queryParameters.containsKey('api_key'), isFalse);
    });

    test('AI TAG 被拦后经 Jina 中转时带上 Jina Key', () async {
      final seen = <http.Request>[];
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          seen.add(req);
          if (req.url.host == 'aitag.win') return http.Response('', 403);
          return http.Response(
            'Title: x\n\nMarkdown Content:\n{"items": [], "total": 0}',
            200,
          );
        }),
        credentials: () async =>
            const OnlineGalleryCredentials(jinaApiKey: 'jina_123'),
      );
      addTearDown(service.dispose);
      await _fetch(service, OnlineGallerySource.aiTag);
      final proxied = seen.where((r) => r.url.host == 'r.jina.ai').toList();
      expect(proxied, isNotEmpty);
      for (final r in proxied) {
        expect(r.headers['Authorization'], 'Bearer jina_123');
      }
      for (final r in seen.where((r) => r.url.host == 'aitag.win')) {
        expect(r.headers.containsKey('Authorization'), isFalse);
      }
    });

    test('Jina 中转 429 时提示可以填 Key', () async {
      final service = OnlineGalleryService(
        client: MockClient((req) async {
          if (req.url.host == 'aitag.win') return http.Response('', 403);
          return http.Response('', 429);
        }),
      );
      addTearDown(service.dispose);
      expect(
        () => _fetch(service, OnlineGallerySource.aiTag),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('Jina Reader Key'),
          ),
        ),
      );
    });
  });
}
