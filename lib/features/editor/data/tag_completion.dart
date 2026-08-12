import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/auth/bot_session_store.dart';
import '../../../core/net/backend_config.dart';
import 'artist_oc_library.dart';
import 'completion_source.dart';
import 'local_tag_db.dart';
import 'role_library.dart';
import 'suggestions.dart';

/// Danbooru wiki 预览(增强模式):标题 + 中/英摘要 + 别名。缩略图因 Cloudflare 不取。
class WikiPreview {
  WikiPreview({
    this.title,
    this.summary,
    this.summaryZh,
    this.otherNames = const [],
  });
  final String? title;
  final String? summary;
  final String? summaryZh;
  final List<String> otherNames;
  bool get hasText =>
      (summary != null && summary!.isNotEmpty) ||
      (summaryZh != null && summaryZh!.isNotEmpty) ||
      otherNames.isNotEmpty;
}

/// 标签补全引擎。按生效来源分流:
///  - `danbooru`:直连 `danbooru.donmai.us/autocomplete.json`,仅英文。
///  - `enhanced`:走后端 `/api/tags/*`——英文过 `/autocomplete` + `/wiki` 补中文;
///    中文过 `/tags/search` 语义搜词。
/// query→result 结果缓存;顺带回填注音/热度缓存([cacheTagMeta]),供词下注音层与词条栏反查。
class TagCompletion {
  TagCompletion({
    required this.source,
    required this.baseUrl,
    required this.localDb,
    required this.roleLib,
    required this.artistOcLib,
    this.sessionId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// 生效来源。
  final CompletionSource source;

  /// 后端基址(enhanced 用),形如 `https://nai.sora214.top`,末尾无斜杠。
  final String baseUrl;

  /// 离线 Danbooru 标签库(danbooru 来源用)。
  final LocalTagDb localDb;

  /// 角色·作品库 + 画师/OC 库(增强模式合并)。
  final RoleLibrary roleLib;
  final ArtistOcLibrary artistOcLib;

  /// bot 会话(库接口 mine 作用域用;Layer 2 接入)。
  final String? sessionId;

  final http.Client _client;

  static const _timeout = Duration(seconds: 12);
  static const _limit = 12;

  // 查询缓存(键=查询串)。超过阈值整表清空,防长会话无界增长——
  // 清空只损失命中率,下次查询重新拉取。
  static const _cacheCap = 500;
  final _cache = <String, SuggestResult>{};
  final _aiCache = <String, List<Suggestion>>{};
  final _relatedCache = <String, List<String>>{};

  static void _capped<K, V>(Map<K, V> m, K k, V v) {
    if (m.length > _cacheCap) m.clear();
    m[k] = v;
  }

  static bool _cjk(String s) => s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

  // 下划线↔空格:app 内标签用空格,Danbooru 用下划线。
  static String _spaces(String s) => s.replaceAll('_', ' ');
  static String _unders(String s) => s.trim().replaceAll(' ', '_');

  /// 查询当前词的补全。失败静默返回空结果(与 web 一致,不弹错)。
  Future<SuggestResult> query(String raw) async {
    final q = raw.trim();
    final cjk = _cjk(q);
    if (cjk ? q.isEmpty : q.length < 2) return const SuggestResult();

    final key = '${source.name}|${q.toLowerCase()}';
    final hit = _cache[key];
    if (hit != null) return hit;

    SuggestResult res;
    try {
      res = source == CompletionSource.danbooru
          ? await _danbooru(q, cjk)
          : await _enhanced(q, cjk);
    } catch (_) {
      res = const SuggestResult();
    }
    if (!res.isEmpty) _capped(_cache, key, res);
    return res;
  }

  /// 关联共现标签(词条栏「关联」)。增强模式走后端 `/api/tags/related`
  /// (DanbooruSearch 共现,web tagRelated.ts 同款参数);离线模式用内置
  /// 静态表(不联网)。空结果也缓存——后端同参 24h 缓存,重复问无意义;
  /// 网络失败不缓存,下次再试。顺带把 cn_name 回填注音缓存。
  Future<List<String>> relatedOf(String name) async {
    final key = name.trim().toLowerCase();
    if (key.isEmpty) return const [];
    final hit = _relatedCache[key];
    if (hit != null) return hit;
    if (source != CompletionSource.enhanced || baseUrl.isEmpty) {
      return relatedTags(key);
    }
    try {
      final r = await _retry(
        () => _client.post(
          Uri.parse('$baseUrl/api/tags/related'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'tags': [_unders(key)],
            'limit': 16,
            'show_nsfw': true,
          }),
        ),
      );
      if (r.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final results = j is Map ? j['results'] : null;
      final out = <String>[];
      if (results is List) {
        for (final e in results) {
          if (e is! Map) continue;
          final tag = e['tag'];
          if (tag is! String || tag.isEmpty) continue;
          final t = _spaces(tag);
          out.add(t);
          final cn = e['cn_name'];
          if (cn is String && cn.isNotEmpty) cacheTagMeta(t, trans: cn);
        }
      }
      _capped(_relatedCache, key, out);
      return out;
    } catch (_) {
      return const [];
    }
  }

  // 复用的持久连接偶发被服务端关闭(“Connection closed before full header”)或瞬断,
  // 抛异常就换新连接重试一次。返回码类错误(403/500 等)有响应、不抛异常,不会到这里。
  Future<http.Response> _retry(Future<http.Response> Function() send) async {
    try {
      return await send().timeout(_timeout);
    } catch (_) {
      return await send().timeout(_timeout);
    }
  }

  // ---- Danbooru 离线库(仅英文,不碰网络/Cloudflare)----
  Future<SuggestResult> _danbooru(String q, bool cjk) async {
    if (cjk) return const SuggestResult(); // 离线英文库
    return SuggestResult(tags: await localDb.search(q, limit: _limit));
  }

  // ---- 后端增强:标签 + 角色作品库 + 画师/OC 库,并行合并 ----
  Future<SuggestResult> _enhanced(String q, bool cjk) async {
    if (baseUrl.isEmpty) return const SuggestResult();
    final tagsF = cjk ? _enhancedChineseTags(q) : _enhancedEnglishTags(q);
    final roleF = roleLib.search(q);
    final aoF = artistOcLib.search(q);
    final tags = await tagsF;
    final (chars, works) = await roleF;
    final (artists, ocs) = await aoF;

    // Danbooru autocomplete 本身含角色/作品/画师类 tag,与库实体同名时
    // 两行重复 → tags 剔除同名(实体行信息更全,保实体);顺手把同名
    // tag 的热度转移给实体(库条目无热度,补上便于热度排序与显示)。
    String norm(String s) => s.trim().toLowerCase().replaceAll('_', ' ');
    final tagCount = <String, int>{
      for (final t in tags)
        if (t.count > 0) norm(t.text): t.count,
    };
    List<Suggestion> fill(List<Suggestion> xs) => [
      for (final s in xs)
        s.count == 0 && (tagCount[norm(s.text)] ?? 0) > 0
            ? s.copyWith(count: tagCount[norm(s.text)])
            : s,
    ];
    final entityNames = <String>{
      for (final s in [...chars, ...works, ...artists, ...ocs]) norm(s.text),
    };
    // D 站角色类目的 tag 归角色分组,排在**本地角色库之后**:库条目自带中文名
    // 与出处,命中就能直接用;D 站那些只有英文名,是补充不是主角。
    final kept = [
      for (final t in tags)
        if (!entityNames.contains(norm(t.text))) t,
    ];
    return SuggestResult(
      tags: [
        for (final t in kept)
          if (t.kind != SuggestionKind.character) t,
      ],
      characters: [
        ...fill(chars),
        for (final t in kept)
          if (t.kind == SuggestionKind.character) t,
      ],
      works: fill(works),
      artists: fill(artists),
      ocs: ocs,
    );
  }

  /// 英文:后端 autocomplete + wiki 补中文译名。
  Future<List<Suggestion>> _enhancedEnglishTags(String q) async {
    final tags = await _backendAutocomplete(q);
    if (tags.isNotEmpty) await _attachTranslations(tags);
    return tags;
  }

  /// 中文:语义搜词(/tags/search)+ AI 推荐(LLM)合并去重。
  Future<List<Suggestion>> _enhancedChineseTags(String q) async {
    final searchF = _backendSearch(q);
    final aiF = _aiTags(q);
    final search = await searchF;
    final ai = await aiF;
    final seen = <String>{};
    final out = <Suggestion>[];
    for (final s in [...search, ...ai]) {
      if (seen.add(s.text.toLowerCase())) out.add(s);
    }
    // 「翻译为英文」行:含中文逗号或 >3 个 CJK 字 → 顶部插一条整句翻译入口
    final cjkCount = q.runes.where((r) => r >= 0x4E00 && r <= 0x9FFF).length;
    if (q.contains('，') || cjkCount > 3) {
      out.insert(
        0,
        Suggestion(
          text: q,
          kind: SuggestionKind.tag,
          trans: '翻译为英文',
          natural: true,
        ),
      );
    }
    return out;
  }

  /// 「翻译为英文」:中文整句 → 流畅英文短句(非标签)。仅选中该行时调。
  Future<String?> translateNatural(String zh) async {
    final content = await _aiCall(
      '你是 AI 绘画提示词翻译器。把中文描述翻译成流畅的英文自然语言短句(用于 NovelAI '
      '生成,不要转成标签格式、不要多余解释),只返回翻译结果。中文:$zh',
      500,
    );
    return content?.trim();
  }

  /// 中文 → Danbooru 标签(AI:直译 1 个 + 推荐 5-8 个),best-effort,缓存防限流。
  Future<List<Suggestion>> _aiTags(String zh) async {
    final hit = _aiCache[zh];
    if (hit != null) return hit;
    final r = await Future.wait([
      _aiCall(
        '将以下中文描述直接翻译为一个英文 Danbooru 标签,用下划线连接单词,全小写,'
        '只输出标签本身、不要任何解释。中文:$zh',
        50,
      ),
      _aiCall(
        '你是 Danbooru 标签专家。根据中文描述推荐 5-8 个最相关且真实存在的 Danbooru '
        '英文标签,每行一个、用下划线连接单词、按相关度排序,只输出标签不要解释。中文:$zh',
        200,
      ),
    ]);
    final seen = <String>{};
    final out = <Suggestion>[];
    for (final t in [
      ..._parseAiTags(r[0], single: true),
      ..._parseAiTags(r[1], single: false),
    ]) {
      final text = t.replaceAll('_', ' ');
      if (seen.add(text)) {
        out.add(Suggestion(text: text, kind: SuggestionKind.tag));
      }
    }
    _capped(_aiCache, zh, out);
    return out;
  }

  Future<String?> _aiCall(String prompt, int maxTokens) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/translate/en2zh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'messages': [
                {'role': 'user', 'content': prompt},
              ],
              'temperature': 0.1,
              'max_tokens': maxTokens,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is Map) {
        final choices = j['choices'];
        if (choices is List && choices.isNotEmpty) {
          final msg = choices.first['message'];
          if (msg is Map) return msg['content'] as String?;
        }
      }
    } catch (_) {}
    return null;
  }

  List<String> _parseAiTags(String? content, {required bool single}) {
    if (content == null) return const [];
    final out = <String>[];
    for (var line in content.split('\n')) {
      line = line.replaceFirst(RegExp(r'^[-*•\d.)\s]+'), '').trim();
      if (line.isEmpty) continue;
      line = line.toLowerCase().replaceAll(' ', '_');
      if (RegExp(r'^[a-z0-9_()]+$').hasMatch(line)) {
        out.add(line);
        if (single || out.length >= 8) break;
      }
    }
    return out;
  }

  Future<List<Suggestion>> _backendAutocomplete(String q) async {
    final uri = Uri.parse(
      '$baseUrl/api/tags/autocomplete',
    ).replace(queryParameters: {'query': q, 'limit': '$_limit'});
    final resp = await _retry(() => _client.get(uri));
    if (resp.statusCode != 200) return const [];
    return _parseDanbooru(resp.bodyBytes, q);
  }

  Future<List<Suggestion>> _backendSearch(String q) async {
    final resp = await _retry(
      () => _client.post(
        Uri.parse('$baseUrl/api/tags/search'),
        headers: {'Content-Type': 'application/json'},
        // 显式带上类目:服务端默认值 2026-08-12 才从 ['General'] 放开到
        // ['General','Character'],不写死的话新旧服务端搜出来的东西不一样。
        body: jsonEncode({
          'query': q,
          'limit': 20,
          'show_nsfw': true,
          'target_categories': ['General', 'Character'],
        }),
      ),
    );
    if (resp.statusCode != 200) return const [];
    final body = jsonDecode(utf8.decode(resp.bodyBytes));
    final results = (body is Map) ? body['results'] : null;
    if (results is! List) return const [];
    final out = <Suggestion>[];
    for (final r in results) {
      if (r is! Map) continue;
      final tag = (r['tag'] as String?)?.trim();
      if (tag == null || tag.isEmpty) continue;
      final text = _spaces(tag);
      final cnRaw = (r['cn_name'] as String?)?.trim();
      final cn = (cnRaw != null && cnRaw.isNotEmpty) ? cnRaw : null;
      final count = (r['count'] as num?)?.toInt() ?? 0;
      cacheTagMeta(text, trans: cn, count: count);
      out.add(
        Suggestion(
          text: text,
          // 语义搜索这边的 category 是字符串('Character'),与 autocomplete
          // 的数字 4 是同一件事,两条路都要认。
          kind: (r['category'] as String?)?.trim().toLowerCase() == 'character'
              ? SuggestionKind.character
              : SuggestionKind.tag,
          trans: cn,
          count: count,
        ),
      );
    }
    return out;
  }

  /// 给英文补全结果补中文名(后端 wiki/词库),best-effort。
  Future<void> _attachTranslations(List<Suggestion> tags) async {
    final names = [for (final t in tags) _unders(t.text)];
    final uri = Uri.parse(
      '$baseUrl/api/tags/wiki',
    ).replace(queryParameters: {'tags': names.join(',')});
    try {
      final resp = await _retry(() => _client.get(uri));
      if (resp.statusCode != 200) return;
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      if (body is! Map) return;
      for (var i = 0; i < tags.length; i++) {
        final zh = body[names[i]];
        if (zh is List && zh.isNotEmpty && zh.first is String) {
          final t = (zh.first as String).trim();
          if (t.isEmpty) continue;
          tags[i] = tags[i].copyWith(trans: t);
          cacheTagMeta(tags[i].text, trans: t);
        }
      }
    } catch (_) {}
  }

  /// 解析 Danbooru `autocomplete.json` 数组 → 标签建议(前缀优先 → 热度降序,剔除 <50 冷门)。
  List<Suggestion> _parseDanbooru(List<int> bytes, String q) {
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! List) return const [];
    final ql = q.toLowerCase();
    final out = <Suggestion>[];
    for (final e in data) {
      if (e is! Map) continue;
      final value = (e['value'] ?? e['name']) as String?;
      if (value == null || value.isEmpty) continue;
      final count = (e['post_count'] as num?)?.toInt() ?? 0;
      if (count != 0 && count < 50) continue; // 冷门标签剔除
      final text = _spaces(value);
      cacheTagMeta(text, count: count);
      out.add(
        Suggestion(
          text: text,
          // Danbooru 的 category 是数字,4 = 角色。归到角色分组去,
          // 混在几十条普通标签里根本挑不出来(对齐 web isCharacter)。
          kind: (e['category'] as num?)?.toInt() == 4
              ? SuggestionKind.character
              : SuggestionKind.tag,
          count: count,
        ),
      );
    }
    out.sort((a, b) {
      final ap = a.text.toLowerCase().startsWith(ql);
      final bp = b.text.toLowerCase().startsWith(ql);
      if (ap != bp) return ap ? -1 : 1;
      return b.count.compareTo(a.count);
    });
    return out;
  }

  /// 拉某标签的 Danbooru wiki 预览(仅增强模式;danbooru/离线返回 null)。文本走后端;
  /// 缩略图(cdn.donmai.us)因 Cloudflare 手机加载不了,不取。
  Future<WikiPreview?> fetchWiki(String tag) async {
    if (source != CompletionSource.enhanced || baseUrl.isEmpty) return null;
    final t = tag.trim().toLowerCase().replaceAll(' ', '_');
    if (t.isEmpty) return null;
    try {
      final pv = await _retry(
        () => _client.get(
          Uri.parse(
            '$baseUrl/api/tags/wiki-preview',
          ).replace(queryParameters: {'tag': t}),
        ),
      );
      if (pv.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(pv.bodyBytes));
      if (j is! Map || j['hasWiki'] != true) return null;
      final other = <String>[];
      final on = j['otherNames'];
      if (on is List) {
        for (final x in on) {
          if (x is String && x.isNotEmpty) other.add(x);
        }
      }
      var summaryZh = j['summaryZh'] as String?;
      if (summaryZh == null || summaryZh.isEmpty) {
        try {
          final zh = await _retry(
            () => _client.get(
              Uri.parse(
                '$baseUrl/api/tags/wiki-preview-summary-zh',
              ).replace(queryParameters: {'tag': t}),
            ),
          );
          if (zh.statusCode == 200) {
            final zj = jsonDecode(utf8.decode(zh.bodyBytes));
            if (zj is Map) summaryZh = zj['summaryZh'] as String?;
          }
        } catch (_) {}
      }
      return WikiPreview(
        title: j['title'] as String?,
        summary: j['summary'] as String?,
        summaryZh: summaryZh,
        otherNames: other,
      );
    } catch (_) {
      return null;
    }
  }

  void dispose() => _client.close();
}

/// 按生效来源 + 后端基址 + 会话构造补全引擎;任一变化即重建(缓存随之刷新)。
final tagCompletionProvider = Provider<TagCompletion>((ref) {
  final source = ref.watch(effectiveCompletionSourceProvider);
  final base = ref.watch(backendBaseProvider).value ?? '';
  final sid = ref.watch(botSessionProvider).value?.sessionId;
  final tc = TagCompletion(
    source: source,
    baseUrl: base,
    sessionId: sid,
    localDb: ref.watch(localTagDbProvider),
    roleLib: ref.watch(roleLibraryProvider),
    artistOcLib: ref.watch(artistOcLibraryProvider),
  );
  ref.onDispose(tc.dispose);
  return tc;
});
