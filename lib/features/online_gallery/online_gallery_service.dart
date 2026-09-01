import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/store/app_stores.dart';
import 'online_gallery_models.dart';

class OnlineGalleryPageResult {
  const OnlineGalleryPageResult({required this.items, required this.hasMore});

  final List<OnlineGalleryItem> items;
  final bool hasMore;
}

/// Small source-neutral HTTP adapter for the mobile online gallery.
///
/// The service intentionally keeps source-specific parsing here. The page and
/// notifier deal only with [OnlineGalleryItem], so adding a new source does not
/// leak API response shapes into the UI.
class OnlineGalleryService {
  OnlineGalleryService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _timeout = Duration(seconds: 25);
  static const _ua = 'Plana-App/1.1 (mobile online gallery)';
  String? _aiTagAssetBase;
  Future<String>? _aiTagAssetBaseLoad;

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
    switch (source) {
      case OnlineGallerySource.danbooru:
      case OnlineGallerySource.safebooru:
        return _fetchDonmai(
          source,
          feed: feed,
          query: query,
          page: page,
          ratings: ratings,
          blacklist: blacklist,
          rankingPeriod: rankingPeriod,
          dateDays: dateDays,
        );
      case OnlineGallerySource.gelbooru:
        return _fetchGelbooru(
          feed: feed,
          query: query,
          page: page,
          ratings: ratings,
          blacklist: blacklist,
          rankingPeriod: rankingPeriod,
          dateDays: dateDays,
        );
      case OnlineGallerySource.aiTag:
        return _fetchAiTag(
          feed: feed,
          query: query,
          page: page,
          blacklist: blacklist,
          rankingPeriod: rankingPeriod,
          dateDays: dateDays,
        );
      case OnlineGallerySource.codex:
        return const OnlineGalleryPageResult(items: [], hasMore: false);
    }
  }

  Future<OnlineGalleryDetail> detail(OnlineGalleryItem item) async {
    switch (item.source) {
      case OnlineGallerySource.danbooru:
      case OnlineGallerySource.safebooru:
        final base = _donmaiBase(item.source);
        final response = await _getJson('$base/posts/${item.id}.json');
        if (response is! Map) throw const FormatException('详情格式异常');
        final parsed = _donmaiItem(item.source, Map<String, dynamic>.from(response));
        return OnlineGalleryDetail(item: parsed, raw: Map<String, dynamic>.from(response));
      case OnlineGallerySource.gelbooru:
        final html = await _getText(
          'https://gelbooru.com/index.php?page=post&s=view&id=${Uri.encodeQueryComponent(item.id)}',
        );
        final parsed = _parseGelbooruDetail(item, html);
        return OnlineGalleryDetail(item: parsed, description: _htmlText(html));
      case OnlineGallerySource.aiTag:
        final assetBase = await _getAiTagAssetBase();
        final response = await _getJson('https://aitag.win/api/work/${Uri.encodeComponent(item.id)}');
        if (response is! Map) throw const FormatException('AI TAG 详情格式异常');
        final copy = item;
        final rows = response['images'];
        var image = copy.imageUrl;
        var prompt = copy.prompt;
        var negativePrompt = copy.negativePrompt;
        if (rows is List && rows.isNotEmpty && rows.first is Map) {
          final row = Map<String, dynamic>.from(rows.first as Map);
          image = _aiTagImageUrl(row, assetBase: assetBase) ?? image;
          final parsedPrompt = _parsePromptPair(
            row['prompt_text']?.toString() ?? row['ai_json']?.toString() ?? '',
          );
          prompt = parsedPrompt.$1.isEmpty ? prompt : parsedPrompt.$1;
          negativePrompt = parsedPrompt.$2.isEmpty
              ? negativePrompt
              : parsedPrompt.$2;
        }
        return OnlineGalleryDetail(
          item: copy.copyWith(
            imageUrl: image,
            previewUrl: image,
            prompt: prompt,
            negativePrompt: negativePrompt,
          ),
          description: _plainText(response['work'] is Map
              ? (response['work'] as Map)['caption']?.toString() ?? ''
              : ''),
          raw: Map<String, dynamic>.from(response),
        );
      case OnlineGallerySource.codex:
        throw const FormatException('法典图鉴使用专用浏览器');
    }
  }

  void dispose() => _client.close();

  Future<Uint8List> download(String url) async {
    final response = await _client
        .get(Uri.parse(url), headers: _headers(url))
        .timeout(_timeout);
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.bodyBytes.isEmpty ||
        contentType.startsWith('text/html') ||
        contentType.startsWith('text/plain')) {
      throw HttpException('图片下载失败 (${response.statusCode})');
    }
    return response.bodyBytes;
  }

  Future<OnlineGalleryPageResult> _fetchDonmai(
    OnlineGallerySource source, {
    required OnlineGalleryFeed feed,
    required String query,
    required int page,
    required Set<String> ratings,
    required Set<String> blacklist,
    required String rankingPeriod,
    required int dateDays,
  }) async {
    final base = _donmaiBase(source);
    var tags = query.trim();
    if (source != OnlineGallerySource.safebooru && ratings.length < 4) {
      final rating = ratings.length == 1
          ? 'rating:${ratings.first}'
          : ratings.map((value) => '~rating:$value').join(' ');
      tags = _join(tags, rating);
    }
    final String url;
    if (feed == OnlineGalleryFeed.ranking) {
      final scale = rankingPeriod;
      url = '$base/explore/posts/popular.json?scale=$scale&page=$page&limit=30';
    } else {
      final date = dateDays > 0
          ? ' date:>=${DateTime.now().subtract(Duration(days: dateDays)).toIso8601String().substring(0, 10)}'
          : '';
      final finalTags = Uri.encodeQueryComponent('$tags$date');
      url = '$base/posts.json?limit=30&page=$page&tags=$finalTags';
    }
    final raw = await _getJson(url);
    if (raw is! List) throw const FormatException('画廊返回格式异常');
    final items = <OnlineGalleryItem>[];
    for (final value in raw) {
      if (value is! Map) continue;
      try {
        final item = _donmaiItem(source, Map<String, dynamic>.from(value));
        if (item.previewUrl.isEmpty ||
            !_passes(item, ratings, blacklist) ||
            !_matchesQuery(item, query) ||
            !_matchesDate(item, dateDays)) {
          continue;
        }
        items.add(item);
      } catch (_) {}
    }
    return OnlineGalleryPageResult(items: items, hasMore: raw.isNotEmpty);
  }

  OnlineGalleryItem _donmaiItem(OnlineGallerySource source, Map<String, dynamic> j) {
    final id = j['id']?.toString() ?? '';
    final file = _string(j['file_url']);
    final large = _string(j['large_file_url']);
    final preview = _string(j['preview_file_url']);
    final tagString = _string(j['tag_string']);
    final tags = tagString.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
    final created = DateTime.tryParse(_string(j['created_at']));
    return OnlineGalleryItem(
      id: id,
      source: source,
      // `preview_file_url` is deliberately tiny (usually 150 px). It looks
      // soft on a tablet, especially after the gallery is shown in six
      // columns. The large CDN rendition is still much smaller than the
      // original and is the right source for a retina-sized card.
      previewUrl: large.isNotEmpty ? large : (preview.isNotEmpty ? preview : file),
      imageUrl: file.isNotEmpty ? file : (large.isNotEmpty ? large : preview),
      width: _int(j['image_width']),
      height: _int(j['image_height']),
      rating: _string(j['rating'], 'g'),
      score: _int(j['score']),
      tags: tags,
      author: _string(j['uploader_name']),
      createdAt: created,
      title: '',
      description: _string(j['source']),
      fileExtension: _string(j['file_ext']),
    );
  }

  Future<OnlineGalleryPageResult> _fetchGelbooru({
    required OnlineGalleryFeed feed,
    required String query,
    required int page,
    required Set<String> ratings,
    required Set<String> blacklist,
    required String rankingPeriod,
    required int dateDays,
  }) async {
    // Gelbooru's public HTML endpoint is more reliable for anonymous mobile
    // clients than the DAPI endpoint, which often requires an API key.
    var tags = query.trim();
    if (ratings.length == 1) {
      tags = _join(tags, 'rating:${_gelRating(ratings.first)}');
    }
    if (dateDays > 0) {
      final date = DateTime.now()
          .subtract(Duration(days: dateDays))
          .toIso8601String()
          .substring(0, 10);
      tags = _join(tags, 'date:>=$date');
    }
    final url = 'https://gelbooru.com/index.php?page=post&s=list&pid=${(page - 1) * 42}&tags=${Uri.encodeQueryComponent(tags)}';
    final html = await _getText(url);
    final items = <OnlineGalleryItem>[];
    final article = RegExp(
      r'''<article[^>]*class=["']thumbnail-preview["'][\s\S]*?</article>''',
      caseSensitive: false,
    );
    for (final match in article.allMatches(html)) {
      final block = match.group(0) ?? '';
      final id = RegExp(r'''id=["']p([^"']+)''', caseSensitive: false).firstMatch(block)?.group(1) ?? '';
      final image = RegExp(r'''<img[^>]+src=["']([^"']+)''', caseSensitive: false).firstMatch(block)?.group(1) ?? '';
      final title = RegExp(r'''\btitle=["']([^"']*)''', caseSensitive: false).firstMatch(block)?.group(1) ?? '';
      if (id.isEmpty || image.isEmpty) continue;
      final tags = _gelTags(title);
      final rating = _ratingFromText(title);
      final item = OnlineGalleryItem(
        id: id,
        source: OnlineGallerySource.gelbooru,
        previewUrl: _normalizeImageUrl(_decodeHtml(image)),
        imageUrl: _normalizeImageUrl(_decodeHtml(image)),
        rating: rating,
        tags: tags,
        title: _decodeHtml(title),
        score: _scoreFromText(title),
      );
      if (_passes(item, ratings, blacklist) &&
          _matchesQuery(item, query) &&
          _matchesDate(item, dateDays)) {
        items.add(item);
      }
    }
    return OnlineGalleryPageResult(items: items, hasMore: items.length >= 20);
  }

  OnlineGalleryItem _parseGelbooruDetail(OnlineGalleryItem base, String html) {
    final image = RegExp(r'''id=["']image["'][^>]+src=["']([^"']+)''', caseSensitive: false).firstMatch(html)?.group(1);
    final section = RegExp(r'''<section[^>]+class=["\'][^"\']*image-container[^"\']*["\'][^>]*''', caseSensitive: false).firstMatch(html)?.group(0) ?? '';
    final tags = RegExp(r'''data-tags=["\']([^"']*)''', caseSensitive: false).firstMatch(section)?.group(1);
    final w = int.tryParse(RegExp(r'''data-width=["\'](\d+)''', caseSensitive: false).firstMatch(section)?.group(1) ?? '') ?? base.width;
    final h = int.tryParse(RegExp(r'''data-height=["\'](\d+)''', caseSensitive: false).firstMatch(section)?.group(1) ?? '') ?? base.height;
    return base.copyWith(
      imageUrl: image == null
          ? base.imageUrl
          : _normalizeImageUrl(_decodeHtml(image)),
      previewUrl: image == null
          ? base.previewUrl
          : _normalizeImageUrl(_decodeHtml(image)),
      width: w,
      height: h,
      tags: tags == null ? base.tags : _gelTags(tags),
    );
  }

  Future<OnlineGalleryPageResult> _fetchAiTag({
    required OnlineGalleryFeed feed,
    required String query,
    required int page,
    required Set<String> blacklist,
    required String rankingPeriod,
    required int dateDays,
  }) async {
    final assetBase = await _getAiTagAssetBase();
    final pageSize = 60;
    final q = query.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).map((x) => '$x::1').join(' ');
    final endpoint = feed == OnlineGalleryFeed.ranking
        ? 'https://aitag.win/api/rank/monthly/real'
        : 'https://aitag.win/api/ai_works_search';
    final params = <String, String>{
      'page': '$page',
      'page_size': '$pageSize',
      'q': q,
      'prompt': '',
      if (feed == OnlineGalleryFeed.search) 'sort': 'new',
      // AI TAG exposes named archive ranges rather than rolling-day values;
      // apply the mobile rolling date filter locally after parsing dates.
      if (feed == OnlineGalleryFeed.search) 'time_range': 'all',
      if (feed == OnlineGalleryFeed.ranking && rankingPeriod != 'day')
        'period': rankingPeriod,
    };
    final uri = Uri.parse(endpoint).replace(queryParameters: params);
    final raw = await _getJson(uri.toString());
    if (raw is! Map) throw const FormatException('AI TAG 返回格式异常');
    final rows = raw['items'];
    if (rows is! List) {
      return const OnlineGalleryPageResult(items: [], hasMore: false);
    }
    final items = <OnlineGalleryItem>[];
    for (final value in rows) {
      if (value is! Map) continue;
      final j = Map<String, dynamic>.from(value);
      final id = _string(j['id']);
      if (id.isEmpty) continue;
      // Search rows do not include image_path, but their user/type/id fields
      // are enough to address the first WebP on the public CDN. Keep the
      // lazy-detail fallback for older or incomplete rows.
      final image = _aiTagImageUrl(j, assetBase: assetBase) ?? '';
      final tags = _parseTagValue(j['tags']);
      final promptPair = _parsePromptPair(
        _string(j['prompt_text'], _string(j['prompt'])),
      );
      final item = OnlineGalleryItem(
        id: id,
        source: OnlineGallerySource.aiTag,
        previewUrl: image,
        imageUrl: image,
        width: _int(j['width']),
        height: _int(j['height']),
        tags: tags,
        author: _string(j['userName']),
        title: _string(j['title']),
        description: _plainText(_string(j['caption'])),
        prompt: promptPair.$1.isNotEmpty
            ? promptPair.$1
            : _string(j['positive_prompt']),
        negativePrompt: promptPair.$2.isNotEmpty
            ? promptPair.$2
            : _string(j['negative_prompt'], _string(j['negativePrompt'])),
        score: _int(j['score']),
        createdAt: DateTime.tryParse(_string(j['create_date'])),
        fileExtension: 'webp',
      );
      if (!_isBlacklisted(item, blacklist) && _matchesDate(item, dateDays)) {
        items.add(item);
      }
    }
    final total = _int(raw['total']);
    return OnlineGalleryPageResult(items: items, hasMore: total == 0 ? rows.isNotEmpty : page * pageSize < total);
  }

  Future<String> _getAiTagAssetBase() async {
    final cached = _aiTagAssetBase;
    if (cached != null && cached.isNotEmpty) return cached;
    final active = _aiTagAssetBaseLoad;
    if (active != null) return active;
    final future = () async {
      try {
        final raw = await _getJson('https://aitag.win/api/config');
        final base = raw is Map
            ? _string(raw['asset_base_url'], 'https://ai-img.10118899.xyz/')
            : 'https://ai-img.10118899.xyz/';
        _aiTagAssetBase = base;
        return base;
      } catch (_) {
        return 'https://ai-img.10118899.xyz/';
      } finally {
        _aiTagAssetBaseLoad = null;
      }
    }();
    _aiTagAssetBaseLoad = future;
    return future;
  }

  Future<Object?> _getJson(String url) async {
    final uri = Uri.parse(url);
    final response = await _client
        .get(uri, headers: _headers(url))
        .timeout(_timeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _decodeJson(response.bodyBytes);
    }

    // aitag.win currently puts /api behind a Cloudflare browser challenge.
    // A native HTTP client cannot execute that challenge, while the site's
    // public CDN remains directly readable. Jina Reader is used only as a
    // JSON transport fallback; the original request is still attempted first
    // so deployments that allow native API access never leave aitag.win.
    if (uri.host.toLowerCase() == 'aitag.win' && response.statusCode == 403) {
      final proxyUrl = _aiTagProxyUrl(uri);
      final proxy = await _client
          .get(Uri.parse(proxyUrl), headers: _headers(proxyUrl))
          .timeout(_timeout);
      if (proxy.statusCode >= 200 && proxy.statusCode < 300) {
        return _decodeJson(proxy.bodyBytes);
      }
    }
    throw HttpException('在线画廊请求失败 (${response.statusCode})');
  }

  String _aiTagProxyUrl(Uri uri) {
    final query = uri.queryParameters.entries.map((entry) =>
        '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}').join('&');
    return 'https://r.jina.ai/http://${uri.host}${uri.path}${query.isEmpty ? '' : '?$query'}';
  }

  Object? _decodeJson(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    try {
      return jsonDecode(text);
    } catch (_) {
      // Jina prefixes API bodies with a short Markdown envelope. Extract
      // the JSON object/array without assuming a particular envelope wording.
      final objectStart = text.indexOf('{');
      final arrayStart = text.indexOf('[');
      final start = objectStart < 0
          ? arrayStart
          : (arrayStart < 0 ? objectStart : (objectStart < arrayStart ? objectStart : arrayStart));
      final objectEnd = text.lastIndexOf('}');
      final arrayEnd = text.lastIndexOf(']');
      final end = objectEnd > arrayEnd ? objectEnd : arrayEnd;
      if (start < 0 || end < start) rethrow;
      return jsonDecode(text.substring(start, end + 1));
    }
  }

  Future<String> _getText(String url) async {
    final response = await _client.get(Uri.parse(url), headers: _headers(url)).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('在线画廊请求失败 (${response.statusCode})');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Map<String, String> _headers(String url) => {
    'User-Agent': _ua,
    'Accept': url.contains('gelbooru.com') ? 'text/html,application/xhtml+xml,application/json' : 'application/json',
    if (url.contains('cdn.donmai.us') || url.contains('donmai.us')) 'Referer': 'https://danbooru.donmai.us/',
    if (url.contains('gelbooru.com')) 'Referer': 'https://gelbooru.com/',
    if (url.contains('aitag.win') || url.contains('ai-img.10118899.xyz'))
      'Referer': 'https://aitag.win/',
  };

  String _donmaiBase(OnlineGallerySource source) => source == OnlineGallerySource.safebooru
      ? 'https://safebooru.donmai.us'
      : 'https://danbooru.donmai.us';

  bool _passes(OnlineGalleryItem item, Set<String> ratings, Set<String> blacklist) =>
      (ratings.length >= 4 || ratings.contains(item.rating)) &&
      !_isBlacklisted(item, blacklist);

  bool _matchesQuery(OnlineGalleryItem item, String query) {
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'[\s,，]+'))
        .where((term) => term.isNotEmpty)
        .toList();
    if (terms.isEmpty) return true;
    final text = '${item.tagText} ${item.title} ${item.author} ${item.description}'
        .toLowerCase();
    return terms.every(text.contains);
  }

  bool _matchesDate(OnlineGalleryItem item, int days) {
    if (days <= 0 || item.createdAt == null) return true;
    final now = DateTime.now();
    final cutoff = days == 1
        ? DateTime(now.year, now.month, now.day)
        : now.subtract(Duration(days: days));
    return item.createdAt!.isAfter(cutoff);
  }

  bool _isBlacklisted(OnlineGalleryItem item, Set<String> blacklist) {
    if (blacklist.isEmpty) return false;
    final normalized = {for (final tag in item.tags) tag.toLowerCase().replaceAll(' ', '_')};
    return blacklist.any((tag) => normalized.contains(tag.toLowerCase().replaceAll(' ', '_')));
  }

  (String, String) _parsePromptPair(String raw) {
    if (raw.trim().isEmpty) return ('', '');
    var value = raw.trim();
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        final positive = decoded['prompt'] ??
            decoded['positive'] ??
            decoded['positive_prompt'] ??
            decoded['parameters'];
        final negative = decoded['negative_prompt'] ??
            decoded['negativePrompt'] ?? decoded['uc'];
        if (positive is! String || positive.trim().isEmpty) {
          return ('', negative?.toString().trim() ?? '');
        }
        return (
          positive.trim(),
          negative?.toString().trim() ?? '',
        );
      }
    } catch (_) {}
    final match = RegExp(
      r'negative prompt\s*:\s*([\s\S]*)',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return (value, '');
    value = value.substring(0, match.start).trimRight();
    return (value, match.group(1)?.trim() ?? '');
  }

  List<String> _parseTagValue(Object? raw) {
    if (raw is List) {
      return [
        for (final value in raw)
          if (value is String && value.trim().isNotEmpty) value.trim(),
      ];
    }
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return [
            for (final value in decoded)
              if (value is String && value.trim().isNotEmpty) value.trim(),
          ];
        }
      } catch (_) {}
      return raw
          .split(RegExp(r'[\s,，]+'))
          .where((value) => value.isNotEmpty)
          .toList();
    }
    return const [];
  }

  String? _aiTagImageUrl(Map<String, dynamic> j, {String? assetBase}) {
    final direct = [
      j['image_url'],
      j['thumbnail_url'],
      j['preview_url'],
      j['cover_url'],
      j['url'],
    ].map((value) => value?.toString().trim() ?? '').firstWhere(
      (value) {
        final uri = Uri.tryParse(value);
        return uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty;
      },
      orElse: () => '',
    );
    if (direct.isNotEmpty) return direct;

    final base = assetBase ??
        _string(j['asset_base_url'], 'https://ai-img.10118899.xyz/');
    final path = _string(j['image_path'], _string(j['imagePath']));
    if (path.isNotEmpty) {
      try {
        return Uri.parse(base).resolve(path).toString();
      } catch (_) {}
    }

    // Search results use a smaller work schema than /api/work: the fields
    // are `AI_type` and `userId`, and omit file_name/image_path. The first
    // CDN rendition is nevertheless deterministic (`<work>_p0.webp`).
    final type = [
      _string(j['image_type']),
      _string(j['ai_type']),
      _string(j['AI_type']),
    ].firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final author = [
      _string(j['author_id']),
      _string(j['userId']),
      _string(j['userid']),
    ].firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final workId = _string(j['id']);
    final file = [
      _string(j['file_name']),
      _string(j['fileName']),
    ].firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final fileName = file.isNotEmpty
        ? (file.endsWith('.webp') ? file : '$file.webp')
        : (workId.isEmpty ? '' : '${workId}_p0.webp');
    if (type.isEmpty || author.isEmpty || fileName.isEmpty) return null;
    final uri = Uri.tryParse(base);
    if (uri == null) return null;
    final baseSegments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return uri
        .replace(
          pathSegments: [...baseSegments, type, author, fileName],
          query: null,
          fragment: null,
        )
        .toString();
  }

  String _join(String left, String right) => right.isEmpty ? left : (left.isEmpty ? right : '$left $right');
  String _gelRating(String value) => switch (value) {'g' => 'general', 's' => 'sensitive', 'q' => 'questionable', _ => 'explicit'};
  String _ratingFromText(String value) => value.contains('rating:explicit') ? 'e' : value.contains('rating:questionable') ? 'q' : value.contains('rating:sensitive') ? 's' : 'g';
  int _scoreFromText(String value) => int.tryParse(RegExp(r'score:(-?\d+)').firstMatch(value)?.group(1) ?? '') ?? 0;
  List<String> _gelTags(String value) => value.replaceAll(RegExp(r'\brating:\w+|\bscore:-?\d+', caseSensitive: false), '').split(RegExp(r'[ ,]+')).where((x) => x.isNotEmpty).toList();
  String _decodeHtml(String value) => value.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>');
  String _normalizeImageUrl(String value) =>
      value.startsWith('//') ? 'https:$value' : value;

  String _plainText(String value) =>
      value.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  String _htmlText(String value) => _plainText(value);
  String _string(Object? value, [String fallback = '']) => value?.toString() ?? fallback;
  int _int(Object? value) => value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

final onlineGalleryServiceProvider = Provider<OnlineGalleryService>((ref) {
  final service = OnlineGalleryService();
  ref.onDispose(service.dispose);
  return service;
});

final onlineGalleryProvider =
    NotifierProvider<OnlineGalleryNotifier, OnlineGalleryState>(
      OnlineGalleryNotifier.new,
    );

class OnlineGalleryNotifier extends Notifier<OnlineGalleryState> {
  static const _favoritesKey = 'online_gallery_favorites_v1';
  static const _blacklistKey = 'online_gallery_blacklist_v1';
  static const _outputFilterKey = 'online_gallery_output_filter_v1';
  int _loadSerial = 0;
  final _details = <String, OnlineGalleryDetail>{};
  final _detailLoads = <String, Future<OnlineGalleryDetail?>>{};
  final _detailFailures = <String>{};

  @override
  OnlineGalleryState build() {
    final prefs = ref.read(prefsStoreProvider);
    final savedFavorites = decodeOnlineFavorites(prefs.get(_favoritesKey));
    final rawBlacklist = prefs.get(_blacklistKey);
    final blacklist = rawBlacklist == null
        ? const <String>{}
        : rawBlacklist.split('\n').where((x) => x.trim().isNotEmpty).toSet();
    Future.microtask(load);
    return OnlineGalleryState(
      favorites: savedFavorites,
      blacklist: blacklist,
      outputFilter: prefs.get(_outputFilterKey) != '0',
    );
  }

  Future<void> load({bool append = false}) async {
    if (state.source == OnlineGallerySource.codex) return;
    if (state.feed == OnlineGalleryFeed.favorites) {
      _refreshFavoritesView();
      return;
    }
    if (state.loading || state.loadingMore) return;
    final serial = ++_loadSerial;
    final page = append ? state.page + 1 : 1;
    state = state.copyWith(
      loading: !append,
      loadingMore: append,
      error: null,
      items: append ? state.items : const [],
      page: page,
    );
    try {
      final result = await ref.read(onlineGalleryServiceProvider).fetch(
        state.source,
        feed: state.feed,
        query: state.query,
        page: page,
        ratings: state.ratings,
        blacklist: state.blacklist,
        rankingPeriod: state.rankingPeriod,
        dateDays: state.dateDays,
      );
      if (serial != _loadSerial) return;
      final old = append ? state.items : const <OnlineGalleryItem>[];
      final seen = {for (final item in old) item.stableId};
      final merged = [
        ...old,
        for (final item in result.items)
          if (seen.add(item.stableId)) item,
      ];
      state = state.copyWith(
        items: merged,
        page: page,
        hasMore: result.hasMore,
        loading: false,
        loadingMore: false,
      );
    } catch (e) {
      if (serial != _loadSerial) return;
      state = state.copyWith(
        loading: false,
        loadingMore: false,
        error: e.toString(),
        page: append ? state.page - 1 : 1,
      );
    }
  }

  void setQuery(String query) {
    _invalidateLoads();
    state = state.copyWith(
      query: query,
      loading: false,
      loadingMore: false,
    );
    if (state.feed == OnlineGalleryFeed.favorites) {
      _refreshFavoritesView();
    }
  }

  void _invalidateLoads() => ++_loadSerial;

  OnlineGalleryItem? itemByStableId(String stableId) {
    for (final item in state.items) {
      if (item.stableId == stableId) return item;
    }
    return null;
  }

  OnlineGalleryDetail? cachedDetail(OnlineGalleryItem item) => _details[item.stableId];

  /// Loads AI TAG's deferred media metadata once per work and patches the card
  /// in place. Other sources also benefit from the cache when a detail page is
  /// reopened.
  Future<OnlineGalleryDetail?> loadDetail(
    OnlineGalleryItem item, {
    bool force = false,
  }) {
    final key = item.stableId;
    final cached = _details[key];
    if (cached != null && !force) return Future.value(cached);
    if (force) _detailFailures.remove(key);
    if (_detailFailures.contains(key)) return Future.value(null);
    final active = _detailLoads[key];
    if (active != null) return active;
    final scopeSource = state.source;
    final future = () async {
      try {
        final detail = await ref.read(onlineGalleryServiceProvider).detail(item);
        _details[key] = detail;
        if (state.source != scopeSource) return detail;
        final nextItems = [
          for (final current in state.items)
            current.stableId == key ? detail.item : current,
        ];
        state = state.copyWith(items: nextItems);
        return detail;
      } catch (_) {
        _detailFailures.add(key);
        return null;
      } finally {
        final removedLoad = _detailLoads.remove(key);
        if (removedLoad != null) {
          // The Future itself is completed here; retaining no reference is
          // intentional and prevents a stale load from blocking retries.
        }
      }
    }();
    _detailLoads[key] = future;
    return future;
  }

  void setRankingPeriod(String value) {
    if (!const {'day', 'week', 'month'}.contains(value)) return;
    _invalidateLoads();
    state = state.copyWith(
      rankingPeriod: value,
      items: const [],
      page: 1,
      hasMore: true,
      loading: false,
      loadingMore: false,
    );
    if (state.feed != OnlineGalleryFeed.favorites &&
        state.source != OnlineGallerySource.codex) {
      load();
    }
  }

  void setDateDays(int value) {
    _invalidateLoads();
    state = state.copyWith(
      dateDays: value < 0 ? 0 : value,
      items: const [],
      page: 1,
      hasMore: true,
      loading: false,
      loadingMore: false,
    );
    if (state.feed != OnlineGalleryFeed.favorites &&
        state.source != OnlineGallerySource.codex) {
      load();
    }
  }

  void setOutputFilter(bool value) {
    state = state.copyWith(outputFilter: value);
    unawaited(
      ref.read(prefsStoreProvider).write(
        key: _outputFilterKey,
        value: value ? '1' : '0',
      ),
    );
  }

  void setSource(OnlineGallerySource source) {
    if (state.source == source) return;
    _invalidateLoads();
    state = state.copyWith(
      source: source,
      feed: OnlineGalleryFeed.search,
      items: const [],
      page: 1,
      hasMore: source != OnlineGallerySource.codex,
      loading: false,
      loadingMore: false,
    );
    if (source != OnlineGallerySource.codex) load();
  }

  void _refreshFavoritesView() {
    ++_loadSerial;
    final terms = state.query
        .trim()
        .toLowerCase()
        .split(RegExp(r'[\s,，]+'))
        .where((value) => value.isNotEmpty)
        .toList();
    final items = [
      for (final item in state.favorites.values)
        if (item.source == state.source &&
            _passesLocal(item) &&
            terms.every(
              (term) =>
                  item.tagText.toLowerCase().contains(term) ||
                  item.title.toLowerCase().contains(term) ||
                  item.author.toLowerCase().contains(term) ||
                  item.description.toLowerCase().contains(term) ||
                  item.prompt.toLowerCase().contains(term),
            ))
          item,
    ];
    state = state.copyWith(items: items, page: 1, hasMore: false);
  }

  void setFeed(OnlineGalleryFeed feed) {
    if (state.feed == feed) {
      if (feed == OnlineGalleryFeed.favorites) _refreshFavoritesView();
      return;
    }
    _invalidateLoads();
    if (feed == OnlineGalleryFeed.favorites) {
      state = state.copyWith(feed: feed);
      _refreshFavoritesView();
      return;
    }
    state = state.copyWith(
      feed: feed,
      items: const [],
      page: 1,
      hasMore: true,
      loading: false,
      loadingMore: false,
    );
    load();
  }

  void setRatings(Set<String> ratings) {
    _invalidateLoads();
    final next = ratings.isEmpty ? const {'g', 's', 'q', 'e'} : ratings;
    state = state.copyWith(
      ratings: next,
      items: const [],
      page: 1,
      hasMore: true,
      loading: false,
      loadingMore: false,
    );
    if (state.feed == OnlineGalleryFeed.favorites) {
      _refreshFavoritesView();
    } else {
      load();
    }
  }

  void setBlacklist(Set<String> blacklist) {
    _invalidateLoads();
    state = state.copyWith(
      blacklist: blacklist,
      items: const [],
      page: 1,
      hasMore: true,
      loading: false,
      loadingMore: false,
    );
    unawaited(
      ref.read(prefsStoreProvider).write(
        key: _blacklistKey,
        value: blacklist.join('\n'),
      ),
    );
    if (state.feed == OnlineGalleryFeed.favorites) {
      _refreshFavoritesView();
    } else {
      load();
    }
  }

  void toggleFavorite(OnlineGalleryItem item) {
    final next = {...state.favorites};
    if (next.remove(item.stableId) == null) next[item.stableId] = item;
    state = state.copyWith(favorites: next);
    unawaited(
      ref.read(prefsStoreProvider).write(
        key: _favoritesKey,
        value: encodeOnlineFavorites(next),
      ),
    );
    if (state.feed == OnlineGalleryFeed.favorites) {
      _refreshFavoritesView();
    }
  }

  bool _passesLocal(OnlineGalleryItem item) {
    if (state.ratings.length < 4 && !state.ratings.contains(item.rating)) {
      return false;
    }
    final normalized = item.tags
        .map((value) => value.toLowerCase().replaceAll(' ', '_'))
        .toSet();
    if (state.blacklist.any(
      (tag) => normalized.contains(tag.toLowerCase().replaceAll(' ', '_')),
    )) {
      return false;
    }
    if (state.dateDays > 0 && item.createdAt != null &&
        item.createdAt!.isBefore(
          (state.dateDays == 1
              ? DateTime(
                  DateTime.now().year,
                  DateTime.now().month,
                  DateTime.now().day,
                )
              : DateTime.now().subtract(Duration(days: state.dateDays))),
        )) {
      return false;
    }
    return true;
  }
}
