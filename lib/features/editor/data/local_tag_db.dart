import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'suggestions.dart';

/// 顶层函数(compute 要求):在后台 isolate 解析整份 TSV。
/// 行格式 `tag<TAB>post_count<TAB>中文<TAB>alias1,alias2`。
List<_Entry> _parseTsv(String raw) {
  final list = <_Entry>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (line.isEmpty) continue;
    final f = line.split('\t');
    if (f.length < 2) continue;
    final count = int.tryParse(f[1]) ?? 0;
    if (count < 50) continue; // 滤冷门,减内存(与 web <50 剔除一致)
    final zh = LocalTagDb.firstZh(
      (f.length > 2 && f[2].isNotEmpty) ? f[2] : null,
    );
    final aliases = (f.length > 3 && f[3].isNotEmpty)
        ? [
            for (final s in f[3].split(','))
              if (s.isNotEmpty && !s.startsWith('/')) s, // 去掉 /lh 之类快捷别名
          ]
        : const <String>[];
    list.add(_Entry(f[0], count, zh, aliases));
  }
  return list;
}

/// 离线 Danbooru 标签库(`assets/danbooru.tsv`,**含中文翻译**,已按热度降序)。
/// token / 未授权模式的英文补全走这里——**完全离线**,不碰网络,天然绕开 Cloudflare。
/// 行格式(tab 分隔):`tag<TAB>post_count<TAB>中文<TAB>alias1,alias2`;
/// tag 用下划线,app 内展示/插入转空格;中文来自社区词库(ChinaGPT 10w + byzod 精选合并)。
class LocalTagDb {
  List<_Entry>? _entries;
  Future<void>? _loading;
  Future<void>? _warming;

  Future<void> _ensureLoaded() {
    if (_entries != null) return Future.value();
    return _loading ??= _load();
  }

  /// 把全库中文/热度灌进 suggestions 反查缓存(注音层/词条栏 sync 查询用)。
  /// 不灌的话翻译只在补全命中时零星回填——手打/带入的既有 prompt 都显示不出。
  /// 约 9 万条,分片让帧;进编辑器时触发,幂等。
  Future<void> warmTagMeta() => _warming ??= _warmTagMeta();

  Future<void> _warmTagMeta() async {
    await _ensureLoaded();
    final entries = _entries;
    if (entries == null) return;
    var i = 0;
    for (final e in entries) {
      if (e.zh != null || e.count > 0) {
        cacheTagMeta(e.tag.replaceAll('_', ' '), trans: e.zh, count: e.count);
      }
      if (++i % 8000 == 0) await Future<void>.delayed(Duration.zero);
    }
  }

  /// 社区词库常一格多译(逗号/顿号/斜杠分隔),注音只取第一个,避免过长。
  /// 非私有:后台解析的顶层函数 [_parseTsv] 要用。
  static String? firstZh(String? zh) {
    if (zh == null) return null;
    var cut = zh.length;
    for (final s in const [',', '，', '、', '/', ';', '；']) {
      final i = zh.indexOf(s);
      if (i >= 0 && i < cut) cut = i;
    }
    final first = zh.substring(0, cut).trim();
    return first.isEmpty ? null : first;
  }

  Future<void> _load() async {
    // rootBundle 是平台通道,只能在主 isolate 读;解析(9 万行、几十万次字符串
    // 分配)扔进后台 isolate。原先整段在主 isolate 同步跑完、一帧都不让,
    // 而触发时机正是用户在编辑器里打字 —— 最在意流畅的场景。见 S3-02。
    final raw = await rootBundle.loadString('assets/danbooru.tsv');
    _entries = await compute(_parseTsv, raw);
  }

  /// 前缀匹配:标签名命中优先、别名命中次之(各自因源已按热度降序)。取前 [limit] 条。
  Future<List<Suggestion>> search(String query, {int limit = 15}) async {
    await _ensureLoaded();
    final entries = _entries;
    if (entries == null) return const [];
    final q = query.trim().toLowerCase().replaceAll(' ', '_');
    if (q.length < 2) return const [];

    final primary = <_Entry>[]; // 标签名前缀命中
    final secondary = <_Entry>[]; // 仅别名前缀命中
    final seen = <String>{};
    for (final e in entries) {
      if (e.tag.startsWith(q)) {
        if (seen.add(e.tag)) primary.add(e);
        if (primary.length >= limit) break; // 已按热度,够了就停
      } else if (secondary.length < limit &&
          e.aliases.any((a) => a.startsWith(q))) {
        if (seen.add(e.tag)) secondary.add(e);
      }
    }
    final out = <Suggestion>[];
    for (final e in [...primary, ...secondary].take(limit)) {
      final text = e.tag.replaceAll('_', ' ');
      cacheTagMeta(text, trans: e.zh, count: e.count); // 回填注音/热度
      out.add(
        Suggestion(
          text: text,
          kind: SuggestionKind.tag,
          trans: e.zh,
          count: e.count,
        ),
      );
    }
    return out;
  }
}

class _Entry {
  _Entry(this.tag, this.count, this.zh, this.aliases);
  final String tag;
  final int count;
  final String? zh; // 中文翻译(可空)
  final List<String> aliases;
}

/// 全局单例(懒加载一次,常驻内存)。
final localTagDbProvider = Provider<LocalTagDb>((ref) => LocalTagDb());
