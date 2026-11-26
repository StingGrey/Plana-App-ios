import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/auth/secure_storage.dart';
import 'online_gallery_models.dart';

/// 在线画廊各来源的自填凭据。全部可选:不填就按匿名访问。
///
/// - Danbooru / Safebooru 同一套账号(donmai.us):用户名 + API Key,走 HTTP Basic;
/// - Gelbooru:User ID + API Key,填了改走官方 DAPI(拿得到原图、尺寸、日期);
/// - AI TAG:站点本身没有开放 Key,它的接口被 Cloudflare 拦下时经 Jina Reader
///   中转,这里填的是 Jina 的 Key(匿名额度很低,刷快了会 429)。
class OnlineGalleryCredentials {
  const OnlineGalleryCredentials({
    this.danbooruLogin = '',
    this.danbooruApiKey = '',
    this.gelbooruUserId = '',
    this.gelbooruApiKey = '',
    this.jinaApiKey = '',
  });

  final String danbooruLogin;
  final String danbooruApiKey;
  final String gelbooruUserId;
  final String gelbooruApiKey;
  final String jinaApiKey;

  bool get hasDanbooru =>
      danbooruLogin.trim().isNotEmpty && danbooruApiKey.trim().isNotEmpty;
  bool get hasGelbooru =>
      gelbooruUserId.trim().isNotEmpty && gelbooruApiKey.trim().isNotEmpty;
  bool get hasJina => jinaApiKey.trim().isNotEmpty;

  bool get isEmpty => !hasDanbooru && !hasGelbooru && !hasJina;

  /// 这个来源用得上的凭据是否已填全。
  bool configuredFor(OnlineGallerySource source) => switch (source) {
    OnlineGallerySource.danbooru ||
    OnlineGallerySource.safebooru => hasDanbooru,
    OnlineGallerySource.gelbooru => hasGelbooru,
    OnlineGallerySource.aiTag => hasJina,
    OnlineGallerySource.codex => false,
  };

  /// 这个来源能不能填凭据(法典是本地内置数据,没有)。
  static bool supports(OnlineGallerySource source) =>
      source != OnlineGallerySource.codex;

  Map<String, String> toJson() => {
    if (danbooruLogin.trim().isNotEmpty) 'danbooruLogin': danbooruLogin.trim(),
    if (danbooruApiKey.trim().isNotEmpty)
      'danbooruApiKey': danbooruApiKey.trim(),
    if (gelbooruUserId.trim().isNotEmpty)
      'gelbooruUserId': gelbooruUserId.trim(),
    if (gelbooruApiKey.trim().isNotEmpty)
      'gelbooruApiKey': gelbooruApiKey.trim(),
    if (jinaApiKey.trim().isNotEmpty) 'jinaApiKey': jinaApiKey.trim(),
  };

  static OnlineGalleryCredentials fromJson(Object? raw) {
    if (raw is! Map) return const OnlineGalleryCredentials();
    String s(String key) => raw[key]?.toString().trim() ?? '';
    return OnlineGalleryCredentials(
      danbooruLogin: s('danbooruLogin'),
      danbooruApiKey: s('danbooruApiKey'),
      gelbooruUserId: s('gelbooruUserId'),
      gelbooruApiKey: s('gelbooruApiKey'),
      jinaApiKey: s('jinaApiKey'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineGalleryCredentials &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Gelbooru「我的账户 → 选项 → API Access Credentials」给的是一整串
/// `&api_key=…&user_id=…`;贴进任一格都能认出两项。认不出返回 null。
({String userId, String apiKey})? parseGelbooruCredentialString(String text) {
  final key = RegExp(r'api_key=([A-Za-z0-9]+)').firstMatch(text)?.group(1);
  final user = RegExp(r'user_id=(\d+)').firstMatch(text)?.group(1);
  if (key == null || user == null) return null;
  return (userId: user, apiKey: key);
}

final onlineGalleryCredentialsProvider =
    AsyncNotifierProvider<
      OnlineGalleryCredentialsNotifier,
      OnlineGalleryCredentials
    >(OnlineGalleryCredentialsNotifier.new);

class OnlineGalleryCredentialsNotifier
    extends AsyncNotifier<OnlineGalleryCredentials> {
  static const _key = 'online_gallery_credentials_v1';

  // 机密,进加密存储;必须走共享的 secureStorageProvider(见其注释)。
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  @override
  Future<OnlineGalleryCredentials> build() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const OnlineGalleryCredentials();
      return OnlineGalleryCredentials.fromJson(jsonDecode(raw));
    } catch (_) {
      // Keystore 没就绪 / 读坏了:按没填过处理,画廊照常匿名可用。
      return const OnlineGalleryCredentials();
    }
  }

  Future<void> save(OnlineGalleryCredentials next) async {
    state = AsyncData(next);
    try {
      if (next.isEmpty) {
        await _storage.delete(key: _key);
      } else {
        await _storage.write(key: _key, value: jsonEncode(next.toJson()));
      }
    } catch (_) {
      // 写不进去只影响下次冷启动,这一程照常能用
    }
  }
}
