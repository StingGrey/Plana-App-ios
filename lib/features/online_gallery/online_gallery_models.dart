import 'dart:convert';

/// Online gallery sources supported by the mobile client.
const Object _onlineUnset = Object();

enum OnlineGallerySource {
  danbooru('danbooru', 'Danbooru'),
  safebooru('safebooru', 'Safebooru'),
  gelbooru('gelbooru', 'Gelbooru'),
  aiTag('ai_tag', 'AI TAG'),
  codex('codex', '法典图鉴');

  const OnlineGallerySource(this.key, this.label);

  final String key;
  final String label;

  static OnlineGallerySource fromKey(Object? value) => values.firstWhere(
    (source) => source.key == value,
    orElse: () => OnlineGallerySource.danbooru,
  );
}

enum OnlineGalleryFeed { search, ranking, favorites }

enum OnlineGalleryRating { general, sensitive, questionable, explicit }

extension OnlineGalleryRatingX on OnlineGalleryRating {
  String get key => switch (this) {
    OnlineGalleryRating.general => 'g',
    OnlineGalleryRating.sensitive => 's',
    OnlineGalleryRating.questionable => 'q',
    OnlineGalleryRating.explicit => 'e',
  };

  String get label => switch (this) {
    OnlineGalleryRating.general => '安全',
    OnlineGalleryRating.sensitive => '敏感',
    OnlineGalleryRating.questionable => '存疑',
    OnlineGalleryRating.explicit => '成人',
  };

  static OnlineGalleryRating? fromKey(String value) {
    for (final rating in OnlineGalleryRating.values) {
      if (rating.key == value) return rating;
    }
    return null;
  }
}

class OnlineGalleryItem {
  const OnlineGalleryItem({
    required this.id,
    required this.source,
    required this.previewUrl,
    required this.imageUrl,
    this.width = 0,
    this.height = 0,
    this.rating = 'g',
    this.score = 0,
    this.tags = const [],
    this.author = '',
    this.createdAt,
    this.title = '',
    this.description = '',
    this.prompt = '',
    this.negativePrompt = '',
    this.fileExtension = '',
  });

  final String id;
  final OnlineGallerySource source;
  final String previewUrl;
  final String imageUrl;
  final int width;
  final int height;
  final String rating;
  final int score;
  final List<String> tags;
  final String author;
  final DateTime? createdAt;
  final String title;
  final String description;
  final String prompt;
  final String negativePrompt;
  final String fileExtension;

  String get stableId => '${source.key}:$id';
  double get aspectRatio => width > 0 && height > 0 ? width / height : 1;
  String get tagText => tags.join(' ');

  OnlineGalleryItem copyWith({
    String? previewUrl,
    String? imageUrl,
    int? width,
    int? height,
    String? rating,
    int? score,
    List<String>? tags,
    String? author,
    DateTime? createdAt,
    String? title,
    String? description,
    String? prompt,
    String? negativePrompt,
    String? fileExtension,
  }) => OnlineGalleryItem(
    id: id,
    source: source,
    previewUrl: previewUrl ?? this.previewUrl,
    imageUrl: imageUrl ?? this.imageUrl,
    width: width ?? this.width,
    height: height ?? this.height,
    rating: rating ?? this.rating,
    score: score ?? this.score,
    tags: tags ?? this.tags,
    author: author ?? this.author,
    createdAt: createdAt ?? this.createdAt,
    title: title ?? this.title,
    description: description ?? this.description,
    prompt: prompt ?? this.prompt,
    negativePrompt: negativePrompt ?? this.negativePrompt,
    fileExtension: fileExtension ?? this.fileExtension,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source.key,
    'previewUrl': previewUrl,
    'imageUrl': imageUrl,
    'width': width,
    'height': height,
    'rating': rating,
    'score': score,
    'tags': tags,
    'author': author,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    'title': title,
    'description': description,
    'prompt': prompt,
    'negativePrompt': negativePrompt,
    'extension': fileExtension,
  };

  static OnlineGalleryItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    final preview = raw['previewUrl']?.toString() ?? '';
    final image = raw['imageUrl']?.toString() ?? '';
    if (id.isEmpty || (preview.isEmpty && image.isEmpty)) return null;
    final rawTags = raw['tags'];
    return OnlineGalleryItem(
      id: id,
      source: OnlineGallerySource.fromKey(raw['source']),
      previewUrl: preview,
      imageUrl: image,
      width: _int(raw['width']),
      height: _int(raw['height']),
      rating: raw['rating']?.toString() ?? 'g',
      score: _int(raw['score']),
      tags: rawTags is List
          ? [for (final tag in rawTags) if (tag is String && tag.isNotEmpty) tag]
          : const [],
      author: raw['author']?.toString() ?? '',
      createdAt: DateTime.tryParse(raw['createdAt']?.toString() ?? ''),
      title: raw['title']?.toString() ?? '',
      description: raw['description']?.toString() ?? '',
      prompt: raw['prompt']?.toString() ?? '',
      negativePrompt: raw['negativePrompt']?.toString() ?? '',
      fileExtension: raw['extension']?.toString() ?? '',
    );
  }
}

class OnlineGalleryDetail {
  const OnlineGalleryDetail({required this.item, this.description = '', this.raw = const {}});

  final OnlineGalleryItem item;
  final String description;
  final Map<String, dynamic> raw;
}

class OnlineGalleryState {
  const OnlineGalleryState({
    this.source = OnlineGallerySource.danbooru,
    this.feed = OnlineGalleryFeed.search,
    this.query = '',
    this.items = const [],
    this.page = 1,
    this.hasMore = true,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.ratings = const {'g', 's', 'q', 'e'},
    this.blacklist = const {},
    this.favorites = const {},
    this.rankingPeriod = 'day',
    this.dateDays = 0,
    this.outputFilter = true,
  });

  final OnlineGallerySource source;
  final OnlineGalleryFeed feed;
  final String query;
  final List<OnlineGalleryItem> items;
  final int page;
  final bool hasMore;
  final bool loading;
  final bool loadingMore;
  final String? error;
  final Set<String> ratings;
  final Set<String> blacklist;
  final Map<String, OnlineGalleryItem> favorites;
  final String rankingPeriod;
  final int dateDays;
  /// When enabled, source-side watermark/censor tags are filtered from the
  /// result list and copied prompt text.
  final bool outputFilter;

  bool isFavorite(OnlineGalleryItem item) => favorites.containsKey(item.stableId);

  /// Items eligible for the selected output filter. The filter follows the
  /// source-neutral tag semantics used by the desktop client: source-side
  /// watermark/censor tags are hidden. Metadata-only rows remain eligible
  /// until a source's detail endpoint resolves the media.
  List<OnlineGalleryItem> get displayItems => outputFilter
      ? [
          for (final item in items)
            if (!_hasOutputNoise(item)) item,
        ]
      : items;

  static String _normalizeOutputTag(String value) {
    var normalized = value.trim().toLowerCase();
    var changed = true;
    while (changed && normalized.isNotEmpty) {
      changed = false;
      while (normalized.startsWith('-')) {
        normalized = normalized.substring(1).trimLeft();
        changed = true;
      }
      final weighted = RegExp(
        r'^[+-]?(?:\d+(?:\.\d+)?|\.\d+)::([\s\S]+)::$',
      ).firstMatch(normalized);
      if (weighted != null) {
        normalized = weighted.group(1)!.trim();
        changed = true;
        continue;
      }
      for (final wrapper in const [('(', ')'), ('[', ']'), ('{', '}')]) {
        if (_fullyWrapped(normalized, wrapper.$1, wrapper.$2)) {
          normalized = normalized.substring(1, normalized.length - 1).trim();
          changed = true;
          break;
        }
      }
    }
    return normalized.replaceAll(RegExp(r'\s+'), '_');
  }

  static bool _fullyWrapped(String value, String opening, String closing) {
    if (value.length < 2 || !value.startsWith(opening) || !value.endsWith(closing)) {
      return false;
    }
    var depth = 0;
    for (var i = 0; i < value.length; i++) {
      if (value[i] == opening) depth++;
      if (value[i] == closing) {
        depth--;
        if (depth == 0 && i != value.length - 1) return false;
        if (depth < 0) return false;
      }
    }
    return depth == 0;
  }

  static const _outputNoiseTags = {
    'watermark',
    'artist_watermark',
    'sample_watermark',
    'censored',
    'censor_bar',
    'mosaic',
    'pixelated',
  };

  static bool _hasOutputNoise(OnlineGalleryItem item) {
    final tags = item.tags.map(_normalizeOutputTag).toSet();
    return tags.any(_outputNoiseTags.contains);
  }

  /// Removes exact source-side noise tags from copied prompt text. It avoids
  /// substring replacement so a tag such as `watermark_style` is preserved.
  String filterOutputPrompt(String prompt) {
    if (!outputFilter || prompt.trim().isEmpty) return prompt.trim();
    return prompt
        .split(RegExp(r'[,，\n]+'))
        .map((part) => part.trim())
        .where((part) {
          final normalized = _normalizeOutputTag(part);
          return normalized.isNotEmpty && !_outputNoiseTags.contains(normalized);
        })
        .join(', ');
  }

  OnlineGalleryState copyWith({
    OnlineGallerySource? source,
    OnlineGalleryFeed? feed,
    String? query,
    List<OnlineGalleryItem>? items,
    int? page,
    bool? hasMore,
    bool? loading,
    bool? loadingMore,
    Object? error = _onlineUnset,
    Set<String>? ratings,
    Set<String>? blacklist,
    Map<String, OnlineGalleryItem>? favorites,
    String? rankingPeriod,
    int? dateDays,
    bool? outputFilter,
  }) => OnlineGalleryState(
    source: source ?? this.source,
    feed: feed ?? this.feed,
    query: query ?? this.query,
    items: items ?? this.items,
    page: page ?? this.page,
    hasMore: hasMore ?? this.hasMore,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    error: error == _onlineUnset ? this.error : error as String?,
    ratings: ratings ?? this.ratings,
    blacklist: blacklist ?? this.blacklist,
    favorites: favorites ?? this.favorites,
    rankingPeriod: rankingPeriod ?? this.rankingPeriod,
    dateDays: dateDays ?? this.dateDays,
    outputFilter: outputFilter ?? this.outputFilter,
  );
}

int _int(Object? value) => value is num ? value.toInt() : int.tryParse('$value') ?? 0;

String encodeOnlineFavorites(Map<String, OnlineGalleryItem> favorites) =>
    jsonEncode([for (final item in favorites.values) item.toJson()]);

Map<String, OnlineGalleryItem> decodeOnlineFavorites(String? value) {
  if (value == null || value.isEmpty) return const {};
  try {
    final raw = jsonDecode(value);
    if (raw is! List) return const {};
    final out = <String, OnlineGalleryItem>{};
    for (final item in raw) {
      final parsed = OnlineGalleryItem.fromJson(item);
      if (parsed != null) out[parsed.stableId] = parsed;
    }
    return out;
  } catch (_) {
    return const {};
  }
}
