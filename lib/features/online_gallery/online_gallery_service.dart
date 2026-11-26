import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/store/app_stores.dart';
import '../editor/data/local_tag_db.dart';
import '../editor/data/tag_index.dart' show TagHit;
import 'online_gallery_credentials.dart';
import 'online_gallery_models.dart';
import 'online_gallery_source_lookup.dart';
import 'ai_tag_metadata.dart';

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
  OnlineGalleryService({
    http.Client? client,
    this._credentials,
    this._localTags,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 每次请求前现取一次用户自填的凭据(见 [OnlineGalleryCredentials]);
  /// null / 读失败 = 匿名。
  final Future<OnlineGalleryCredentials> Function()? _credentials;

  /// 离线词库的英文补全(`LocalTagDb.search`),搜索框联想的兜底;null = 没有兜底。
  final LocalTagSearch? _localTags;
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
    final creds = await _creds();
    switch (source) {
      case OnlineGallerySource.danbooru:
      case OnlineGallerySource.safebooru:
        return _fetchDonmai(
          source,
          creds: creds,
          feed: feed,
          query: query,
          page: page,
          ratings: ratings,
          blacklist: blacklist,
          rankingPeriod: rankingPeriod,
          dateDays: dateDays,
        );
      case OnlineGallerySource.gelbooru:
        if (creds.hasGelbooru) {
          return _fetchGelbooruApi(
            creds: creds,
            query: query,
            page: page,
            ratings: ratings,
            blacklist: blacklist,
            dateDays: dateDays,
          );
        }
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
          creds: creds,
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

  Future<OnlineGalleryCredentials> _creds() async {
    try {
      return await _credentials?.call() ?? const OnlineGalleryCredentials();
    } catch (_) {
      return const OnlineGalleryCredentials();
    }
  }

  Future<OnlineGalleryDetail> detail(OnlineGalleryItem item) async {
    final creds = await _creds();
    switch (item.source) {
      case OnlineGallerySource.danbooru:
      case OnlineGallerySource.safebooru:
        final response = await _getJson(
          '$_donmaiApi/posts/${item.id}.json',
          creds: creds,
        );
        if (response is! Map) throw const FormatException('详情格式异常');
        final parsed = _donmaiItem(
          item.source,
          Map<String, dynamic>.from(response),
        );
        return OnlineGalleryDetail(
          item: parsed,
          raw: Map<String, dynamic>.from(response),
        );
      case OnlineGallerySource.gelbooru:
        final html = await _getText(
          'https://gelbooru.com/index.php?page=post&s=view&id=${Uri.encodeQueryComponent(item.id)}',
        );
        final parsed = _parseGelbooruDetail(item, html);
        // Gelbooru exposes tags, not an AI prompt. Never pass the complete
        // HTML document to the prompt editor; the caller falls back to tags.
        return OnlineGalleryDetail(item: parsed);
      case OnlineGallerySource.aiTag:
        final assetBase = await _getAiTagAssetBase(creds);
        final response = await _getJson(
          'https://aitag.win/api/work/${Uri.encodeComponent(item.id)}',
          creds: creds,
        );
        if (response is! Map) throw const FormatException('AI TAG 详情格式异常');
        final work = response['work'] is Map
            ? response['work'] as Map
            : const {};
        final rows = response['images'] is List
            ? (response['images'] as List).whereType<Map>().toList()
            : <Map>[];
        int pageIndex(Map row) =>
            int.tryParse(
              RegExp(r'_p(\d+)').firstMatch('${row['file_name']}')?.group(1) ??
                  '',
            ) ??
            0;
        rows.sort((a, b) => pageIndex(a).compareTo(pageIndex(b)));
        final images = <OnlineGalleryItem>[];
        for (final rawRow in rows) {
          final row = Map<String, dynamic>.from(rawRow);
          final image =
              _aiTagImageUrl(row, assetBase: assetBase) ?? item.imageUrl;
          final prompts = parseAiTagPrompts(row);
          images.add(
            item.copyWith(
              imageUrl: image,
              previewUrl: image,
              prompt: prompts.positive,
              negativePrompt: prompts.negative,
              promptSource: prompts.source,
              negativePromptSource: prompts.negativeSource,
              platform: aiPlatform(
                row['image_type'] ??
                    work['AI_type'] ??
                    work['ai_type'] ??
                    item.platform,
              ),
            ),
          );
        }
        return OnlineGalleryDetail(
          item: images.isEmpty ? item : images.first,
          images: images,
          description: _plainText(work['caption']?.toString() ?? ''),
          raw: Map<String, dynamic>.from(response),
        );
      case OnlineGallerySource.codex:
        throw const FormatException('法典图鉴使用专用浏览器');
    }
  }

  /// 搜索框的标签联想。[term] 是光标所在那个词(`-` / `~` 前缀已去掉)。
  ///
  /// Danbooru / Safebooru 用站点自己的 autocomplete(带别名,中日文的其他名也认,
  /// 和网页版那个下拉同一份);Gelbooru 用 autocomplete2。站点连不上、没结果,
  /// 以及 AI TAG(搜的是提示词原文)都退回离线词库。
  Future<List<GalleryTagSuggestion>> suggestTags(
    OnlineGallerySource source,
    String term, {
    int limit = 10,
  }) async {
    final q = term.trim();
    if (q.isEmpty || source == OnlineGallerySource.codex) return const [];
    try {
      final online = switch (source) {
        OnlineGallerySource.danbooru ||
        OnlineGallerySource.safebooru => await _danbooruSuggest(q, limit),
        OnlineGallerySource.gelbooru => await _gelbooruSuggest(q, limit),
        _ => const <GalleryTagSuggestion>[],
      };
      if (online.isNotEmpty) return online;
    } catch (_) {
      // 联想只是锦上添花:站点挂了、限流了都退回离线词库,不打扰输入
    }
    return _localSuggest(q, limit);
  }

  Future<List<GalleryTagSuggestion>> _danbooruSuggest(
    String q,
    int limit,
  ) async {
    final url = Uri.https('danbooru.donmai.us', '/autocomplete.json', {
      'search[query]': q,
      'search[type]': 'tag_query',
      'version': '1',
      'limit': '$limit',
    }).toString();
    final raw = await _getJson(url, creds: await _creds());
    if (raw is! List) return const [];
    final out = <GalleryTagSuggestion>[];
    for (final v in raw) {
      if (v is! Map) continue;
      final value = _string(v['value']).trim();
      if (value.isEmpty) continue;
      final type = _string(v['type']);
      // rating: / order: 这类元标签的取值:label 只是半截(general),显示全名
      final meta = type == 'static' || type == 'metatag';
      final antecedent = _string(v['antecedent']).trim();
      out.add(
        GalleryTagSuggestion(
          value: value,
          label: meta ? value : _string(v['label'], value.replaceAll('_', ' ')),
          category: meta
              ? OnlineGalleryTagCategory.meta
              : donmaiTagCategory(_int(v['category'])),
          postCount: _int(v['post_count']),
          antecedent: antecedent.isEmpty ? null : antecedent,
        ),
      );
    }
    return out;
  }

  Future<List<GalleryTagSuggestion>> _gelbooruSuggest(
    String q,
    int limit,
  ) async {
    final url = Uri.https('gelbooru.com', '/index.php', {
      'page': 'autocomplete2',
      'term': q,
      'type': 'tag_query',
      'limit': '$limit',
    }).toString();
    final raw = await _getJson(url);
    if (raw is! List) return const [];
    return [
      for (final v in raw)
        if (v is Map && _string(v['value']).trim().isNotEmpty)
          GalleryTagSuggestion(
            value: _string(v['value']).trim(),
            label: _string(
              v['label'],
              _string(v['value']).replaceAll('_', ' '),
            ),
            category: switch (_string(v['category'])) {
              'artist' => OnlineGalleryTagCategory.artist,
              'character' => OnlineGalleryTagCategory.character,
              'copyright' => OnlineGalleryTagCategory.copyright,
              'metadata' || 'meta' => OnlineGalleryTagCategory.meta,
              'tag' || 'general' => OnlineGalleryTagCategory.general,
              _ => OnlineGalleryTagCategory.unknown,
            },
            postCount: _int(v['post_count']),
          ),
    ];
  }

  Future<List<GalleryTagSuggestion>> _localSuggest(String q, int limit) async {
    final search = _localTags;
    if (search == null) return const [];
    try {
      final hits = await search(q, limit: limit);
      return [
        for (final h in hits)
          GalleryTagSuggestion(
            value: h.tag.trim().replaceAll(' ', '_'),
            label: h.tag.trim().replaceAll('_', ' '),
            category: donmaiTagCategory(h.category),
            postCount: h.count,
            translation: h.zh,
          ),
      ];
    } catch (_) {
      return const [];
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
    required OnlineGalleryCredentials creds,
    required OnlineGalleryFeed feed,
    required String query,
    required int page,
    required Set<String> ratings,
    required Set<String> blacklist,
    required String rankingPeriod,
    required int dateDays,
  }) async {
    const base = _donmaiApi;
    final safe = source == OnlineGallerySource.safebooru;
    // 粘贴的出处链接(Pixiv / X …)换成 Danbooru 认的反查写法
    var tags = rewriteGallerySourceQuery(query);
    if (safe) {
      // rating: 不占匿名用户的两个标签名额
      tags = _join(tags, 'rating:g');
    } else if (ratings.length < 4) {
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
    final raw = await _getJson(url, creds: creds);
    if (raw is! List) throw const FormatException('画廊返回格式异常');
    final items = <OnlineGalleryItem>[];
    for (final value in raw) {
      if (value is! Map) continue;
      try {
        final item = _donmaiItem(source, Map<String, dynamic>.from(value));
        if (item.previewUrl.isEmpty ||
            // 排行榜接口不吃 tags,Safebooru 的全年龄只能在这里筛
            (safe && item.rating != 'g') ||
            !_passes(item, ratings, blacklist) ||
            // 搜索接口已经按 tags 筛过;本地再按字面筛一遍会把 `-tag`、
            // `pixiv:123`、`source:*…*` 这类元标签的结果全吞掉,只给排行用
            (feed == OnlineGalleryFeed.ranking &&
                !_matchesQuery(item, query)) ||
            !_matchesDate(item, dateDays)) {
          continue;
        }
        items.add(item);
      } catch (_) {}
    }
    return OnlineGalleryPageResult(items: items, hasMore: raw.isNotEmpty);
  }

  OnlineGalleryItem _donmaiItem(
    OnlineGallerySource source,
    Map<String, dynamic> j,
  ) {
    final id = j['id']?.toString() ?? '';
    final file = _string(j['file_url']);
    final large = _string(j['large_file_url']);
    final preview = _string(j['preview_file_url']);
    final tagString = _string(j['tag_string']);
    final tags = tagString
        .split(RegExp(r'\s+'))
        .where((x) => x.isNotEmpty)
        .toList();
    final created = DateTime.tryParse(_string(j['created_at']));
    return OnlineGalleryItem(
      id: id,
      source: source,
      // `preview_file_url` is deliberately tiny (usually 150 px). It looks
      // soft on a tablet, especially after the gallery is shown in six
      // columns. The large CDN rendition is still much smaller than the
      // original and is the right source for a retina-sized card.
      previewUrl: large.isNotEmpty
          ? large
          : (preview.isNotEmpty ? preview : file),
      imageUrl: file.isNotEmpty ? file : (large.isNotEmpty ? large : preview),
      width: _int(j['image_width']),
      height: _int(j['image_height']),
      rating: _string(j['rating'], 'g'),
      score: _int(j['score']),
      tags: tags,
      tagCategories: {
        for (final category in OnlineGalleryTagCategory.values)
          for (final tag in _string(
            j['tag_string_${category.name}'],
          ).split(RegExp(r'\s+')))
            if (tag.isNotEmpty) tag: category,
      },
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
    // Gelbooru treats an empty `tags` value as an unfiltered first page and
    // ignores `pid`. Use its explicit all-posts tag so page 2 advances when
    // the user has not entered a search term.
    final requestTags = tags.trim().isEmpty ? 'all' : tags;
    final url =
        'https://gelbooru.com/index.php?page=post&s=list&pid=${(page - 1) * 42}&tags=${Uri.encodeQueryComponent(requestTags)}';
    final html = await _getText(url);
    final items = <OnlineGalleryItem>[];
    final article = RegExp(
      r'''<article[^>]*class=["']thumbnail-preview["'][\s\S]*?</article>''',
      caseSensitive: false,
    );
    final articles = article.allMatches(html).toList(growable: false);
    for (final match in articles) {
      final block = match.group(0) ?? '';
      final id =
          RegExp(
            r'''id=["']p([^"']+)''',
            caseSensitive: false,
          ).firstMatch(block)?.group(1) ??
          '';
      final image =
          RegExp(
            r'''<img[^>]+src=["']([^"']+)''',
            caseSensitive: false,
          ).firstMatch(block)?.group(1) ??
          '';
      final title =
          RegExp(
            r'''\btitle=["']([^"']*)''',
            caseSensitive: false,
          ).firstMatch(block)?.group(1) ??
          '';
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
    // Pagination is based on the number of source cards, not the number
    // surviving local filters. Otherwise a blacklist/rating selection can
    // incorrectly make page one look like the end of the Gelbooru feed.
    return OnlineGalleryPageResult(
      items: items,
      hasMore: articles.length >= 20,
    );
  }

  /// 填了 Gelbooru 的 User ID + API Key 时走官方 DAPI:每张带原图地址、尺寸、
  /// 分级、上传者和日期,比匿名抓 HTML 列表(只有缩略图和 title 里的标签)全。
  Future<OnlineGalleryPageResult> _fetchGelbooruApi({
    required OnlineGalleryCredentials creds,
    required String query,
    required int page,
    required Set<String> ratings,
    required Set<String> blacklist,
    required int dateDays,
  }) async {
    const limit = 42;
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
    final uri = Uri.https('gelbooru.com', '/index.php', {
      'page': 'dapi',
      's': 'post',
      'q': 'index',
      'json': '1',
      'limit': '$limit',
      // DAPI 的 pid 是页码(从 0 起),不是 HTML 列表那种条目偏移
      'pid': '${page - 1}',
      if (tags.trim().isNotEmpty) 'tags': tags.trim(),
      'api_key': creds.gelbooruApiKey.trim(),
      'user_id': creds.gelbooruUserId.trim(),
    });
    final raw = await _getJson(uri.toString(), creds: creds);
    if (raw is! Map && raw is! List) {
      throw const FormatException('Gelbooru 返回格式异常');
    }
    // 没结果时只有 @attributes、没有 post;只有一条时个别版本给的是对象
    final posts = raw is List ? raw : (raw as Map)['post'];
    final rows = posts is List
        ? posts
        : posts is Map
        ? [posts]
        : const [];
    final items = <OnlineGalleryItem>[];
    for (final value in rows) {
      if (value is! Map) continue;
      try {
        final item = _gelbooruApiItem(Map<String, dynamic>.from(value));
        if (item.id.isEmpty || item.previewUrl.isEmpty) continue;
        if (_passes(item, ratings, blacklist) &&
            _matchesQuery(item, query) &&
            _matchesDate(item, dateDays)) {
          items.add(item);
        }
      } catch (_) {}
    }
    final attrs = raw is Map && raw['@attributes'] is Map
        ? raw['@attributes'] as Map
        : null;
    final count = _int(attrs?['count']);
    return OnlineGalleryPageResult(
      items: items,
      hasMore: count > 0 ? page * limit < count : rows.length >= limit,
    );
  }

  OnlineGalleryItem _gelbooruApiItem(Map<String, dynamic> j) {
    final file = _normalizeImageUrl(_string(j['file_url']));
    final sample = _normalizeImageUrl(_string(j['sample_url']));
    final preview = _normalizeImageUrl(_string(j['preview_url']));
    final extension =
        RegExp(
          r'\.([A-Za-z0-9]+)(?:[?#]|$)',
        ).firstMatch(file)?.group(1)?.toLowerCase() ??
        '';
    final video = const {
      'mp4',
      'webm',
      'mkv',
      'mov',
      'avi',
    }.contains(extension);
    // 卡片用 sample(平板上 150px 的 preview 太糊);视频没有静态大图,退回 preview
    final display = sample.isNotEmpty ? sample : (video ? preview : file);
    return OnlineGalleryItem(
      id: _string(j['id']),
      source: OnlineGallerySource.gelbooru,
      previewUrl: display.isNotEmpty ? display : preview,
      imageUrl: video
          ? (display.isNotEmpty ? display : preview)
          : (file.isNotEmpty ? file : display),
      width: _int(j['width']),
      height: _int(j['height']),
      rating: switch (_string(j['rating']).toLowerCase()) {
        'explicit' || 'e' => 'e',
        'questionable' || 'q' => 'q',
        'sensitive' || 's' => 's',
        _ => 'g',
      },
      score: _int(j['score']),
      tags: _gelTags(_decodeHtml(_string(j['tags']))),
      author: _string(j['owner']),
      createdAt: parseGelbooruDate(_string(j['created_at'])),
      title: _decodeHtml(_string(j['title'])),
      description: _string(j['source']),
      fileExtension: extension,
    );
  }

  OnlineGalleryItem _parseGelbooruDetail(OnlineGalleryItem base, String html) {
    final section =
        RegExp(
          r'''<section\b[^>]*\bclass=["'][^"']*\bimage-container\b[^"']*["'][^>]*>''',
          caseSensitive: false,
        ).firstMatch(html)?.group(0) ??
        '';
    final imageTag =
        RegExp(
          r'''<img\b[^>]*\bid\s*=\s*["']image["'][^>]*>''',
          caseSensitive: false,
        ).firstMatch(html)?.group(0) ??
        '';
    String attribute(String name, String source) =>
        RegExp(
          "$name\\s*=\\s*[\\\"']([^\\\"']*)",
          caseSensitive: false,
        ).firstMatch(source)?.group(1) ??
        '';

    final image = attribute('src', imageTag);
    final tags = attribute('data-tags', section);
    final w =
        int.tryParse(attribute('data-width', section)) ??
        int.tryParse(attribute('width', imageTag)) ??
        base.width;
    final h =
        int.tryParse(attribute('data-height', section)) ??
        int.tryParse(attribute('height', imageTag)) ??
        base.height;
    final categories = <String, OnlineGalleryTagCategory>{};
    final categorizedTags = RegExp(
      r"""<li\b[^>]*class=["'][^"']*tag-type-(artist|copyright|character|general|metadata|meta)[^"']*["'][^>]*>([\s\S]*?)</li>""",
      caseSensitive: false,
    );
    for (final match in categorizedTags.allMatches(html)) {
      final name = match.group(1)!.toLowerCase();
      final category = OnlineGalleryTagCategory.values.byName(
        name == 'metadata' ? 'meta' : name,
      );
      for (final link in RegExp(
        r"""<a\b[^>]*href=["']([^"']*)["'][^>]*>([\s\S]*?)</a>""",
        caseSensitive: false,
      ).allMatches(match.group(2)!)) {
        final href = _decodeHtml(link.group(1)!);
        if (!href.contains('s=list') || !href.contains('tags=')) continue;
        final tag = _plainText(link.group(2)!).trim().replaceAll(' ', '_');
        if (tag.isNotEmpty) categories[tag] = category;
      }
    }
    // 经 DAPI 来的条目(带尺寸)已经是原图地址,别被详情页里的缩放图换掉
    final hasOriginal =
        base.width > 0 && base.height > 0 && base.imageUrl.isNotEmpty;
    return base.copyWith(
      imageUrl: image.isEmpty || hasOriginal
          ? base.imageUrl
          : _normalizeImageUrl(_decodeHtml(image)),
      // Keep the list thumbnail as a reliable fallback. The detail `src` is
      // often a protected/original rendition and should not replace it.
      previewUrl: base.previewUrl.isNotEmpty
          ? base.previewUrl
          : image.isEmpty
          ? base.previewUrl
          : _normalizeImageUrl(_decodeHtml(image)),
      width: w,
      height: h,
      tags: tags.isEmpty
          ? {...base.tags, ...categories.keys}.toList()
          : _gelTags(_decodeHtml(tags)),
      tagCategories: {...base.tagCategories, ...categories},
    );
  }

  Future<OnlineGalleryPageResult> _fetchAiTag({
    required OnlineGalleryCredentials creds,
    required OnlineGalleryFeed feed,
    required String query,
    required int page,
    required Set<String> blacklist,
    required String rankingPeriod,
    required int dateDays,
  }) async {
    final assetBase = await _getAiTagAssetBase(creds);
    final pageSize = 60;
    final q = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((x) => x.isNotEmpty)
        .map((x) => '$x::1')
        .join(' ');
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
    final raw = await _getJson(uri.toString(), creds: creds);
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
        platform: aiPlatform(j['AI_type'] ?? j['ai_type']),
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
    return OnlineGalleryPageResult(
      items: items,
      hasMore: total == 0 ? rows.isNotEmpty : page * pageSize < total,
    );
  }

  Future<String> _getAiTagAssetBase(OnlineGalleryCredentials creds) async {
    final cached = _aiTagAssetBase;
    if (cached != null && cached.isNotEmpty) return cached;
    final active = _aiTagAssetBaseLoad;
    if (active != null) return active;
    final future = () async {
      try {
        final raw = await _getJson(
          'https://aitag.win/api/config',
          creds: creds,
        );
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

  Future<Object?> _getJson(
    String url, {
    OnlineGalleryCredentials creds = const OnlineGalleryCredentials(),
  }) async {
    final uri = Uri.parse(url);
    final headers = _headers(url, creds: creds);
    final response = await _client.get(uri, headers: headers).timeout(_timeout);
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
          .get(Uri.parse(proxyUrl), headers: _headers(proxyUrl, creds: creds))
          .timeout(_timeout);
      if (proxy.statusCode >= 200 && proxy.statusCode < 300) {
        return _decodeJson(proxy.bodyBytes);
      }
      throw HttpException(switch (proxy.statusCode) {
        401 || 403 when creds.hasJina =>
          'Jina Reader API Key 无效 (${proxy.statusCode})',
        429 =>
          creds.hasJina
              ? 'Jina Reader 额度用完了,稍后再试 (429)'
              : 'AI TAG 中转请求太频繁,稍后再试,或在「API Key」里填 Jina Reader Key (429)',
        _ => 'AI TAG 中转请求失败 (${proxy.statusCode})',
      });
    }
    if (isCloudflareChallenge(response)) {
      throw HttpException(
        '${uri.host} 开了 Cloudflare 人机验证,App 里没法直连 (${response.statusCode})',
      );
    }
    final authed =
        headers.containsKey('Authorization') ||
        uri.queryParameters.containsKey('api_key');
    if (authed && (response.statusCode == 401 || response.statusCode == 403)) {
      throw HttpException('API Key 无效或没有权限 (${response.statusCode})');
    }
    throw HttpException('在线画廊请求失败 (${response.statusCode})');
  }

  String _aiTagProxyUrl(Uri uri) {
    final query = uri.queryParameters.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
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
          : (arrayStart < 0
                ? objectStart
                : (objectStart < arrayStart ? objectStart : arrayStart));
      final objectEnd = text.lastIndexOf('}');
      final arrayEnd = text.lastIndexOf(']');
      final end = objectEnd > arrayEnd ? objectEnd : arrayEnd;
      if (start < 0 || end < start) rethrow;
      return jsonDecode(text.substring(start, end + 1));
    }
  }

  Future<String> _getText(String url) async {
    final response = await _client
        .get(Uri.parse(url), headers: _headers(url))
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('在线画廊请求失败 (${response.statusCode})');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Map<String, String> _headers(
    String url, {
    OnlineGalleryCredentials creds = const OnlineGalleryCredentials(),
  }) => {
    'User-Agent': _ua,
    'Accept': url.contains('gelbooru.com')
        ? 'text/html,application/xhtml+xml,application/json'
        : 'application/json',
    if (url.contains('cdn.donmai.us') || url.contains('donmai.us'))
      'Referer': 'https://danbooru.donmai.us/',
    if (url.contains('gelbooru.com')) 'Referer': 'https://gelbooru.com/',
    if (url.contains('aitag.win') || url.contains('ai-img.10118899.xyz'))
      'Referer': 'https://aitag.win/',
    ...?_authHeader(url, creds),
  };

  /// 按主机精确匹配才带凭据:donmai 的接口域名用 Basic(图片 CDN 不带),
  /// Jina 中转用 Bearer。Gelbooru 的 DAPI 只认查询参数,不走这里。
  Map<String, String>? _authHeader(String url, OnlineGalleryCredentials creds) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (creds.hasDanbooru &&
        (host == 'danbooru.donmai.us' || host == 'safebooru.donmai.us')) {
      final pair =
          '${creds.danbooruLogin.trim()}:${creds.danbooruApiKey.trim()}';
      return {'Authorization': 'Basic ${base64Encode(utf8.encode(pair))}'};
    }
    if (creds.hasJina && host == 'r.jina.ai') {
      return {'Authorization': 'Bearer ${creds.jinaApiKey.trim()}'};
    }
    return null;
  }

  /// Danbooru 与 Safebooru 的接口都走这里。
  ///
  /// safebooru.donmai.us 是同一个站只看全年龄(rating:g)的那一面,同一个库、
  /// 同一套账号;但它整站挂在 Cloudflare 浏览器验证后面,原生请求不论带不带
  /// Key 一律 403 —— 以前带了 Key 就报成「API Key 无效」,看着像两边 Key 不
  /// 通用。所以 Safebooru 改走 Danbooru 接口并钉 `rating:g`,同一把 Key 两边都用。
  static const _donmaiApi = 'https://danbooru.donmai.us';

  bool _passes(
    OnlineGalleryItem item,
    Set<String> ratings,
    Set<String> blacklist,
  ) =>
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
    final text =
        '${item.tagText} ${item.title} ${item.author} ${item.description}'
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
    final normalized = {
      for (final tag in item.tags) tag.toLowerCase().replaceAll(' ', '_'),
    };
    return blacklist.any(
      (tag) => normalized.contains(tag.toLowerCase().replaceAll(' ', '_')),
    );
  }

  (String, String) _parsePromptPair(String raw) {
    if (raw.trim().isEmpty) return ('', '');
    var value = raw.trim();
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        final positive =
            decoded['prompt'] ??
            decoded['positive'] ??
            decoded['positive_prompt'] ??
            decoded['parameters'];
        final negative =
            decoded['negative_prompt'] ??
            decoded['negativePrompt'] ??
            decoded['uc'];
        if (positive is! String || positive.trim().isEmpty) {
          return ('', negative?.toString().trim() ?? '');
        }
        return (positive.trim(), negative?.toString().trim() ?? '');
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
    final direct =
        [
          j['image_url'],
          j['thumbnail_url'],
          j['preview_url'],
          j['cover_url'],
          j['url'],
        ].map((value) => value?.toString().trim() ?? '').firstWhere((value) {
          final uri = Uri.tryParse(value);
          return uri != null &&
              (uri.scheme == 'http' || uri.scheme == 'https') &&
              uri.host.isNotEmpty;
        }, orElse: () => '');
    if (direct.isNotEmpty) return direct;

    final base =
        assetBase ??
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

  String _join(String left, String right) =>
      right.isEmpty ? left : (left.isEmpty ? right : '$left $right');
  String _gelRating(String value) => switch (value) {
    'g' => 'general',
    's' => 'sensitive',
    'q' => 'questionable',
    _ => 'explicit',
  };
  String _ratingFromText(String value) => value.contains('rating:explicit')
      ? 'e'
      : value.contains('rating:questionable')
      ? 'q'
      : value.contains('rating:sensitive')
      ? 's'
      : 'g';
  int _scoreFromText(String value) =>
      int.tryParse(
        RegExp(r'score:(-?\d+)').firstMatch(value)?.group(1) ?? '',
      ) ??
      0;
  List<String> _gelTags(String value) => value
      .replaceAll(
        RegExp(r'\brating:\w+|\bscore:-?\d+', caseSensitive: false),
        '',
      )
      .split(RegExp(r'[ ,]+'))
      .where((x) => x.isNotEmpty)
      .toList();
  String _decodeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  String _normalizeImageUrl(String value) {
    final decoded = value.trim();
    if (decoded.startsWith('//')) return 'https:$decoded';
    if (decoded.startsWith('/')) return 'https://gelbooru.com$decoded';
    return decoded;
  }

  String _plainText(String value) => value
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  String _string(Object? value, [String fallback = '']) =>
      value?.toString() ?? fallback;
  int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

/// Gelbooru DAPI 的 `created_at` 是 `Sat Nov 23 10:12:01 -0600 2024` 这种
/// Ruby 风格;认不出时再按 ISO 试一次,都不行返回 null。
DateTime? parseGelbooruDate(String raw) {
  final m = RegExp(
    r'^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+([+-])(\d{2})(\d{2})\s+(\d{4})$',
  ).firstMatch(raw.trim());
  if (m == null) return DateTime.tryParse(raw.trim());
  const months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final month = months.indexOf(m.group(1)!.toLowerCase()) + 1;
  if (month == 0) return null;
  final local = DateTime.utc(
    int.parse(m.group(9)!),
    month,
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
  );
  final offset = Duration(
    hours: int.parse(m.group(7)!),
    minutes: int.parse(m.group(8)!),
  );
  // 18:00 -0500 = 23:00 UTC
  return m.group(6) == '-' ? local.add(offset) : local.subtract(offset);
}

final onlineGalleryServiceProvider = Provider<OnlineGalleryService>((ref) {
  final service = OnlineGalleryService(
    credentials: () => ref.read(onlineGalleryCredentialsProvider.future),
    localTags: ref.watch(localTagDbProvider).search,
  );
  // 凭据改了(在 API Key 面板里保存):不重建服务,下一次请求自然取到新的
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
  static const _platformFilterKey = 'online_gallery_excluded_platforms_v1';
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
      excludedPlatforms: (prefs.get(_platformFilterKey) ?? '')
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toSet(),
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
      listRevision: append ? state.listRevision : state.listRevision + 1,
      loading: !append,
      loadingMore: append,
      error: null,
      items: append ? state.items : const [],
      page: page,
    );
    try {
      final result = await ref
          .read(onlineGalleryServiceProvider)
          .fetch(
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
    // 排行榜接口不吃 tags:在排行页粘贴出处链接,切回搜索才查得到
    final toSearch =
        state.feed == OnlineGalleryFeed.ranking &&
        _searchesDonmai(state.source) &&
        gallerySourceLookupIn(query) != null;
    state = state.copyWith(
      query: query,
      feed: toSearch ? OnlineGalleryFeed.search : null,
      items: toSearch ? const [] : null,
      page: toSearch ? 1 : null,
      hasMore: toSearch ? true : null,
      loading: false,
      loadingMore: false,
    );
    if (state.feed == OnlineGalleryFeed.favorites) {
      _refreshFavoritesView();
    }
  }

  /// 拿一条出处链接去 Danbooru 反查。当前已在 Danbooru / Safebooru 就原地查,
  /// 其他来源(Gelbooru、AI TAG)切到 Danbooru。
  void lookupSource(String url) {
    _invalidateLoads();
    state = state.copyWith(
      query: url.trim(),
      source: _searchesDonmai(state.source)
          ? state.source
          : OnlineGallerySource.danbooru,
      feed: OnlineGalleryFeed.search,
      items: const [],
      page: 1,
      hasMore: true,
      loading: false,
      loadingMore: false,
    );
    unawaited(load());
  }

  static bool _searchesDonmai(OnlineGallerySource source) =>
      source == OnlineGallerySource.danbooru ||
      source == OnlineGallerySource.safebooru;

  void _invalidateLoads() {
    ++_loadSerial;
    state = state.copyWith(listRevision: state.listRevision + 1);
  }

  /// API Key 改了:丢掉进行中的请求和详情缓存,按新凭据重拉当前列表。
  void reloadForCredentials() {
    _details.clear();
    _detailFailures.clear();
    _invalidateLoads();
    state = state.copyWith(loading: false, loadingMore: false);
    unawaited(load());
  }

  OnlineGalleryItem? itemByStableId(String stableId) {
    for (final item in state.items) {
      if (item.stableId == stableId) return item;
    }
    return null;
  }

  OnlineGalleryDetail? cachedDetail(OnlineGalleryItem item) =>
      _details[item.stableId];

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
        final detail = await ref
            .read(onlineGalleryServiceProvider)
            .detail(item);
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

  void setExcludedPlatforms(Set<String> value) {
    state = state.copyWith(
      excludedPlatforms: value,
      listRevision: state.listRevision + 1,
    );
    unawaited(
      ref
          .read(prefsStoreProvider)
          .write(key: _platformFilterKey, value: value.join('\n')),
    );
  }

  void setOutputFilter(bool value) {
    state = state.copyWith(
      outputFilter: value,
      listRevision: state.listRevision + 1,
    );
    unawaited(
      ref
          .read(prefsStoreProvider)
          .write(key: _outputFilterKey, value: value ? '1' : '0'),
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
      ref
          .read(prefsStoreProvider)
          .write(key: _blacklistKey, value: blacklist.join('\n')),
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
      ref
          .read(prefsStoreProvider)
          .write(key: _favoritesKey, value: encodeOnlineFavorites(next)),
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
    if (state.dateDays > 0 &&
        item.createdAt != null &&
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

/// Cloudflare 的浏览器验证页(「Just a moment...」):原生 HTTP 客户端过不去,
/// 和 Key 对不对无关,别报成 Key 无效。
bool isCloudflareChallenge(http.Response response) {
  if (response.statusCode != 403 && response.statusCode != 503) return false;
  if (response.headers['cf-mitigated'] == 'challenge') return true;
  final type = (response.headers['content-type'] ?? '').toLowerCase();
  if (!type.contains('html')) return false;
  final head = utf8.decode(
    response.bodyBytes.take(4096).toList(),
    allowMalformed: true,
  );
  return head.contains('Just a moment') ||
      head.contains('challenge-platform') ||
      head.contains('cf-chl');
}

/// 离线词库英文补全的签名(`LocalTagDb.search`)。
typedef LocalTagSearch =
    Future<List<TagHit>> Function(String query, {int limit});

/// Danbooru 类目号(离线词库同口径):0 一般 / 1 画师 / 3 作品 / 4 角色 / 5 meta。
OnlineGalleryTagCategory donmaiTagCategory(int category) => switch (category) {
  0 => OnlineGalleryTagCategory.general,
  1 => OnlineGalleryTagCategory.artist,
  3 => OnlineGalleryTagCategory.copyright,
  4 => OnlineGalleryTagCategory.character,
  5 => OnlineGalleryTagCategory.meta,
  _ => OnlineGalleryTagCategory.unknown,
};

/// 搜索框联想的一条。
class GalleryTagSuggestion {
  const GalleryTagSuggestion({
    required this.value,
    required this.label,
    this.category = OnlineGalleryTagCategory.unknown,
    this.postCount = 0,
    this.antecedent,
    this.translation,
  });

  /// 填进搜索框的写法(下划线形态,元标签带前缀)。
  final String value;
  final String label;
  final OnlineGalleryTagCategory category;
  final int postCount;

  /// 输入命中的是别名 / 其他名(比如「初音ミク」)时的那个原词。
  final String? antecedent;

  /// 词库自带的中文;没有时界面再去共享缓存里反查。
  final String? translation;
}
