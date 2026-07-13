import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/net/backend_config.dart';
import 'suggestions.dart';

/// 角色·作品库(增强模式):后端 `GET /api/data/role_tag_mapping.json`(~6.5MB,中英双语,公开)。
/// 首次拉取写本地缓存文件,之后读本地;解析成角色列表 + 作品→角色索引,供中/英搜索。
/// **只在增强(bot)模式用**;离线模式不涉及(不拉 6.5MB 后端数据)。
class RoleLibrary {
  RoleLibrary(this.baseUrl, this._client);

  final String baseUrl;
  final http.Client _client;

  final _rand = Random();
  List<_Role>? _roles;
  List<_Origin>? _origins;
  Future<void>? _loading;

  Future<void> _ensureLoaded() {
    if (_roles != null) return Future.value();
    return _loading ??= _load();
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/role_tag_mapping.json');
  }

  Future<void> _load() async {
    String? raw;
    // 1) 本地缓存
    try {
      final f = await _cacheFile();
      if (await f.exists()) raw = await f.readAsString();
    } catch (_) {}
    // 2) 拉取 + 落盘
    if (raw == null || raw.isEmpty) {
      if (baseUrl.isEmpty) {
        _roles = const [];
        _origins = const [];
        return;
      }
      try {
        final resp = await _client
            .get(Uri.parse('$baseUrl/api/data/role_tag_mapping.json'))
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          _roles = const [];
          _origins = const [];
          return;
        }
        raw = utf8.decode(resp.bodyBytes);
        try {
          await (await _cacheFile()).writeAsString(raw);
        } catch (_) {}
      } catch (_) {
        _roles = const [];
        _origins = const [];
        return;
      }
    }
    _parse(raw);
  }

  void _parse(String raw) {
    final roles = <_Role>[];
    final originMap = <String, _Origin>{};
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        for (final v in map.values) {
          if (v is! Map) continue;
          final roleEn = v['role_en'] as String?;
          if (roleEn == null || roleEn.isEmpty) continue;
          final roleZh = _firstStr(v['role_zh']);
          final originEn = (v['origin_en'] as String?) ?? '';
          final originZh = _firstStr(v['origin_zh']);
          final r = _Role(roleEn, roleZh, originEn, originZh);
          roles.add(r);
          if (originEn.isNotEmpty) {
            (originMap[originEn] ??= _Origin(originEn, originZh)).roles.add(r);
          }
        }
      }
    } catch (_) {}
    _roles = roles;
    _origins = originMap.values.toList();
  }

  static String? _firstStr(dynamic v) {
    if (v is List) {
      for (final e in v) {
        if (e is String && e.trim().isNotEmpty) return e.trim();
      }
    }
    return null;
  }

  /// 搜角色 + 作品。中文匹配译名(子串),英文匹配角色名/作品名前缀。→ (characters, works)。
  Future<(List<Suggestion>, List<Suggestion>)> search(
    String query, {
    int limit = 6,
  }) async {
    try {
      await _ensureLoaded();
    } catch (_) {
      return (const <Suggestion>[], const <Suggestion>[]);
    }
    final roles = _roles, origins = _origins;
    if (roles == null || origins == null) {
      return (const <Suggestion>[], const <Suggestion>[]);
    }
    final q = query.trim();
    if (q.isEmpty) return (const <Suggestion>[], const <Suggestion>[]);
    final cjk = q.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);
    final ql = q.toLowerCase().replaceAll(' ', '_');

    final chars = <Suggestion>[];
    for (final r in roles) {
      final hit = cjk
          ? (r.roleZh?.contains(q) ?? false)
          : r.roleEn.startsWith(ql);
      if (hit) {
        chars.add(
          Suggestion(
            text: r.roleEn.replaceAll('_', ' '),
            kind: SuggestionKind.character,
            trans: r.roleZh,
            source:
                r.originZh ??
                (r.originEn.isEmpty ? null : r.originEn.replaceAll('_', ' ')),
          ),
        );
        if (chars.length >= limit) break;
      }
    }

    final works = <Suggestion>[];
    for (final o in origins) {
      if (o.roles.isEmpty) continue;
      final hit = cjk ? (o.zh?.contains(q) ?? false) : o.en.startsWith(ql);
      if (hit) {
        // 作品选中=随机抽一个角色插入(对齐 web)
        final pick = o.roles[_rand.nextInt(o.roles.length)];
        works.add(
          Suggestion(
            text: o.en.replaceAll('_', ' '),
            kind: SuggestionKind.work,
            trans: o.zh,
            note: '${o.roles.length} 个角色 · 随机抽取',
            insertText: pick.roleEn.replaceAll('_', ' '),
          ),
        );
        if (works.length >= limit) break;
      }
    }
    return (chars, works);
  }
}

class _Role {
  _Role(this.roleEn, this.roleZh, this.originEn, this.originZh);
  final String roleEn;
  final String? roleZh;
  final String originEn;
  final String? originZh;
}

class _Origin {
  _Origin(this.en, this.zh);
  final String en;
  final String? zh;
  final List<_Role> roles = [];
}

/// 按后端基址构造(基址变即重建)。
final roleLibraryProvider = Provider<RoleLibrary>((ref) {
  final base = ref.watch(backendBaseProvider).value ?? '';
  final lib = RoleLibrary(base, http.Client());
  return lib;
});
