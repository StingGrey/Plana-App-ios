/// 按出处反查 Danbooru:把一条来源链接(Pixiv / X / Fanbox …)换成 Danbooru
/// 的搜索词,在线画廊搜索框里粘贴链接就能找到对应的帖子。
///
/// Danbooru 的 `source:` 只做不区分大小写的字面前缀匹配,不会把链接规范化:
/// Pixiv 帖子存的是 i.pximg.net 原图地址(作品页链接搜不到),X 存 x.com
/// (twitter.com 的写法搜不到)。所以能从链接里拿到作品 ID 的站一律按 ID
/// 搭通配;拿不到 ID 的才退回「去掉协议和 www 的整段链接」前后加通配。
library;

class GallerySourceLookup {
  const GallerySourceLookup({
    required this.site,
    required this.ref,
    required this.term,
    required this.pageUrl,
  });

  /// 站名,提示条里显示,例如 `Pixiv`。
  final String site;

  /// 链接里认出来的作品标识(ID、短码),提示条里显示。
  final String ref;

  /// 交给 Danbooru 的搜索词,例如 `pixiv:122778833`。
  final String term;

  /// 浏览器里打开用的作品页。Pixiv 原图地址有防盗链,换成作品页。
  final String pageUrl;
}

/// 查询里第一条能认出来的来源链接;没有就是 null。
GallerySourceLookup? gallerySourceLookupIn(String query) {
  for (final token in query.trim().split(RegExp(r'\s+'))) {
    final lookup = gallerySourceLookup(token);
    if (lookup != null) return lookup;
  }
  return null;
}

/// 把查询里的来源链接换成 Danbooru 搜索词,其余标签原样保留。
String rewriteGallerySourceQuery(String query) => query
    .trim()
    .split(RegExp(r'\s+'))
    .map((token) => gallerySourceLookup(token)?.term ?? token)
    .join(' ');

/// 认一条链接。带协议的链接都能认(认不出的站走整段通配);不带协议时只认
/// 下面列出的站,免得把 `k/da_(league_of_legends)` 这种标签当成链接。
GallerySourceLookup? gallerySourceLookup(String input) {
  final raw = input.trim();
  if (raw.isEmpty || raw.contains(RegExp(r'\s'))) return null;
  final hasScheme = RegExp(r'^https?://', caseSensitive: false).hasMatch(raw);
  if (!hasScheme && !raw.contains('/')) return null;
  final uri = Uri.tryParse(hasScheme ? raw : 'https://$raw');
  if (uri == null || !uri.host.contains('.')) return null;
  final host = uri.host.toLowerCase().replaceFirst(
    RegExp(r'^(www|m|mobile)\.'),
    '',
  );
  // Danbooru 自己的帖子链接直接按 ID 打开;它的搜索页之类不是出处,不当链接
  if (host == 'donmai.us' || host.endsWith('.donmai.us')) {
    final id = RegExp(r'^/posts?/(?:show/)?(\d+)').firstMatch(uri.path)?[1];
    if (id == null) return null;
    return GallerySourceLookup(
      site: 'Danbooru',
      ref: '#$id',
      term: 'id:$id',
      pageUrl: 'https://danbooru.donmai.us/posts/$id',
    );
  }
  return _known(uri, host, uri.path) ?? (hasScheme ? _generic(uri) : null);
}

GallerySourceLookup? _known(Uri uri, String host, String path) {
  RegExpMatch? m(String pattern) =>
      RegExp(pattern, caseSensitive: false).firstMatch(path);
  bool on(String domain) => host == domain || host.endsWith('.$domain');

  String? pixivId;
  if (on('pixiv.net') || on('phixiv.net') || on('ppxiv.net')) {
    pixivId =
        m(r'^/(?:[a-z]{2}/)?(?:artworks|i)/(\d+)')?.group(1) ??
        (path.endsWith('member_illust.php')
            ? uri.queryParameters['illust_id']
            : null);
  } else if (on('pximg.net')) {
    pixivId = m(r'/(\d+)_[^/]*$')?.group(1);
  }
  if (pixivId != null && RegExp(r'^\d+$').hasMatch(pixivId)) {
    return GallerySourceLookup(
      site: 'Pixiv',
      ref: pixivId,
      term: 'pixiv:$pixivId',
      pageUrl: 'https://www.pixiv.net/artworks/$pixivId',
    );
  }

  const twitterHosts = {
    'twitter.com',
    'x.com',
    'vxtwitter.com',
    'fxtwitter.com',
    'fixupx.com',
    'fixvx.com',
    'twittpr.com',
  };
  if (twitterHosts.contains(host) || host.startsWith('nitter.')) {
    final id = m(r'/status(?:es)?/(\d+)')?.group(1);
    if (id == null) return null;
    return GallerySourceLookup(
      site: 'X',
      ref: id,
      // 老帖存 twitter.com、新帖存 x.com,还有 /i/web/status/ 的写法
      term: 'source:*status/$id*',
      pageUrl: 'https://x.com/i/status/$id',
    );
  }
  if (host == 'pbs.twimg.com') {
    final name = m(r'^/media/([A-Za-z0-9_-]+)')?.group(1);
    if (name == null) return null;
    return GallerySourceLookup(
      site: 'X',
      ref: name,
      term: 'source:*twimg.com/media/$name*',
      pageUrl: uri.toString(),
    );
  }

  if (host == 'bsky.app') {
    final rkey = m(r'^/profile/[^/]+/post/([a-z0-9]+)')?.group(1);
    if (rkey == null) return null;
    return GallerySourceLookup(
      site: 'Bluesky',
      ref: rkey,
      // 库里存的是 did:plc:…,粘贴来的多半是 handle,中间段放通配
      term: 'source:*bsky.app/profile/*/post/$rkey*',
      pageUrl: uri.toString(),
    );
  }

  if (on('fanbox.cc')) {
    final id = m(r'^/(?:@[^/]+/)?posts/(\d+)')?.group(1);
    if (id == null) return null;
    return GallerySourceLookup(
      site: 'Fanbox',
      ref: id,
      // fanbox.cc/@user 和 user.fanbox.cc 两种写法
      term: 'source:*fanbox.cc*/posts/$id*',
      pageUrl: uri.toString(),
    );
  }

  if (on('artstation.com')) {
    final hash = m(r'/(?:artwork|projects)/([A-Za-z0-9]+)')?.group(1);
    if (hash == null) return null;
    return GallerySourceLookup(
      site: 'ArtStation',
      ref: hash,
      // artstation.com/artwork/x 和 user.artstation.com/projects/x 两种写法
      term: 'source:*artstation.com*/$hash*',
      pageUrl: 'https://www.artstation.com/artwork/$hash',
    );
  }

  if (on('tumblr.com')) {
    final id = m(r'^/post/(\d+)')?.group(1) ?? m(r'^/[^/]+/(\d+)')?.group(1);
    if (id == null) return null;
    return GallerySourceLookup(
      site: 'Tumblr',
      ref: id,
      term: 'source:*tumblr.com*$id*',
      pageUrl: uri.toString(),
    );
  }

  if (on('bilibili.com')) {
    final id = host == 't.bilibili.com'
        ? m(r'^/(\d+)')?.group(1)
        : m(r'^/(?:opus|dynamic)/(\d+)')?.group(1);
    if (id == null) return null;
    return GallerySourceLookup(
      site: 'Bilibili',
      ref: id,
      // t.bilibili.com/<id> 和 www.bilibili.com/opus/<id> 是同一条动态
      term: 'source:*bilibili.com*$id*',
      pageUrl: uri.toString(),
    );
  }
  return null;
}

/// 分享链接常带的跟踪参数,整段通配时去掉,不然一个字符都对不上。
const _trackingParams = {
  's',
  't',
  'si',
  'ref',
  'ref_src',
  'share',
  'feature',
  'from',
  'spm_id_from',
  'vd_source',
  'igsh',
};

GallerySourceLookup? _generic(Uri uri) {
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.isEmpty && uri.query.isEmpty) return null;
  final query = uri.query
      .split('&')
      .where((pair) {
        if (pair.isEmpty) return false;
        final key = pair.split('=').first.toLowerCase();
        return !key.startsWith('utm_') && !_trackingParams.contains(key);
      })
      .join('&');
  final rest = '$host$path${query.isEmpty ? '' : '?$query'}';
  if (rest.contains('*')) return null;
  final tail = uri.pathSegments.where((s) => s.isNotEmpty);
  return GallerySourceLookup(
    site: host,
    ref: tail.isEmpty ? '' : tail.last,
    term: 'source:*$rest*',
    pageUrl: uri.toString(),
  );
}
