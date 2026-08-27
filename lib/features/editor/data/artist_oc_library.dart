import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/auth/bot_session_store.dart';
import '../../../core/net/backend_config.dart';
import 'suggestions.dart';

/// 画师串 + OC 库(增强模式,需 Bearer session)。
/// `GET /api/artists/list` + `GET /api/oc/list`,内存缓存(会话生命周期)。
/// **画师插 `artist_string`、OC 插 `tag_group`**——web 包成 `<<marker>>` 但发送前会被
/// `cleanPromptMarkers` 剥成裸内容,故直接插裸载荷等价。归属默认 all(不按 mine 过滤)。
class ArtistOcLibrary {
  ArtistOcLibrary(this.baseUrl, this.sessionId, this._client);

  final String baseUrl;
  final String? sessionId;
  final http.Client _client;

  List<_Artist>? _artists;
  List<_Oc>? _ocs;
  Future<void>? _loading;

  Future<void> _ensureLoaded() {
    if (_artists != null && _ocs != null) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    if (baseUrl.isEmpty || sessionId == null || sessionId!.isEmpty) {
      _artists = const [];
      _ocs = const [];
      return;
    }
    final headers = {'Authorization': 'Bearer $sessionId'};
    try {
      final r = await _client
          .get(Uri.parse('$baseUrl/api/artists/list'), headers: headers)
          .timeout(const Duration(seconds: 15));
      _artists = _parseArtists(r);
    } catch (_) {
      _artists = const [];
    }
    try {
      final r = await _client
          .get(Uri.parse('$baseUrl/api/oc/list'), headers: headers)
          .timeout(const Duration(seconds: 15));
      _ocs = _parseOcs(r);
    } catch (_) {
      _ocs = const [];
    }
  }

  List<_Artist> _parseArtists(http.Response r) {
    if (r.statusCode != 200) return const [];
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final list = (j is Map) ? j['artists'] : null;
    if (list is! List) return const [];
    final out = <_Artist>[];
    for (final a in list) {
      if (a is! Map) continue;
      final name = a['name'] as String?;
      final str = a['artist_string'] as String?;
      if (name == null || name.isEmpty || str == null || str.isEmpty) continue;
      out.add(_Artist(name, str));
    }
    return out;
  }

  List<_Oc> _parseOcs(http.Response r) {
    if (r.statusCode != 200) return const [];
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final list = (j is Map) ? j['ocs'] : null;
    if (list is! List) return const [];
    final out = <_Oc>[];
    for (final o in list) {
      if (o is! Map) continue;
      final en = o['en_name'] as String?;
      final zh = o['zh_name'] as String?;
      final group = o['tag_group'] as String?;
      final name = (zh != null && zh.isNotEmpty) ? zh : en;
      if (name == null || name.isEmpty || group == null || group.isEmpty) {
        continue;
      }
      final aliases = <String>[];
      final al = o['zh_aliases'];
      if (al is List) {
        for (final x in al) {
          if (x is String && x.isNotEmpty) aliases.add(x);
        }
      }
      out.add(_Oc(name, en, group, aliases));
    }
    return out;
  }

  /// 画师匹配名字子串;OC 匹配名字/别名子串。→ (artists, ocs)。
  Future<(List<Suggestion>, List<Suggestion>)> search(
    String query, {
    int limit = 5,
  }) async {
    try {
      await _ensureLoaded();
    } catch (_) {
      return (const <Suggestion>[], const <Suggestion>[]);
    }
    final artists = _artists, ocs = _ocs;
    if (artists == null || ocs == null) {
      return (const <Suggestion>[], const <Suggestion>[]);
    }
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return (const <Suggestion>[], const <Suggestion>[]);

    final aOut = <Suggestion>[];
    for (final a in artists) {
      if (a.name.toLowerCase().contains(q)) {
        aOut.add(
          Suggestion(
            text: a.name,
            kind: SuggestionKind.artist,
            insertText: a.artistString,
          ),
        );
        if (aOut.length >= limit) break;
      }
    }
    final oOut = <Suggestion>[];
    for (final o in ocs) {
      final hit =
          o.name.toLowerCase().contains(q) ||
          o.aliases.any((x) => x.toLowerCase().contains(q));
      if (hit) {
        oOut.add(
          Suggestion(
            text: o.name,
            kind: SuggestionKind.oc,
            trans: (o.en != null && o.en != o.name) ? o.en : null,
            note: '插入角色配置',
            insertText: o.tagGroup,
          ),
        );
        if (oOut.length >= limit) break;
      }
    }
    return (aOut, oOut);
  }
}

class _Artist {
  _Artist(this.name, this.artistString);
  final String name;
  final String artistString;
}

class _Oc {
  _Oc(this.name, this.en, this.tagGroup, this.aliases);
  final String name;
  final String? en;
  final String tagGroup;
  final List<String> aliases;
}

/// 按后端基址 + 会话构造(任一变即重建,缓存刷新)。
final artistOcLibraryProvider = Provider<ArtistOcLibrary>((ref) {
  final base = ref.watch(backendBaseProvider).value ?? '';
  final sid = ref.watch(botSessionProvider).value?.sessionId;
  return ArtistOcLibrary(base, sid, http.Client());
});
