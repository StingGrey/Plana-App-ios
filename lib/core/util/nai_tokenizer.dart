/// NAI T5 提示词 token 计数 —— 与 web 端读数逐数一致。
///
/// web 用 @huggingface/tokenizers@0.1.3(纯 JS 实现)+ t5_tokenizer.json
/// 实时计数;这里移植其 encode 管线里"计数需要的全部语义",词表就是
/// web 同一份 JSON(assets/t5_tokenizer.json,字节级同源):
///
///   Precompiled 归一化(删控制符 → 一批空白类/零宽字符归一成空格 →
///     NFKC,含"全角波浪线不参与 NFKC"的 quirk;JS 版不查 charsmap,照抄)
///   → WhitespaceSplit(JS `\S+`)→ Metaspace(空格→U+2581、逐段加前缀)
///   → Unigram Viterbi(unk 分 = minScore-10;某起点无单码点命中才插 unk 节点;
///     平分时先插入的节点赢 —— 与 JS 的严格大于同构)
///   → fuse_unk(连续 unk 并成一个)
///   → TemplateProcessing(结尾一枚 </s>,+1)。
///
/// 有意不移植的部分(域内到不了,与 web 差异为零):added_token 的
/// lstrip/rstrip(本词表全 false)、normalized added token(本词表没有)、
/// 字面 `<unk>` 后继 unk 被丢弃的 fuse 怪癖(不影响计数)。
/// 逐数一致由 test/nai_tokenizer_test.dart 钉住(答案由 web 同款包生成)。
///
/// 本文件的不可见字符一律写 `\uXXXX` 编译期转义(非 raw 字符串),
/// 源码只留可见 ASCII —— 字面不可见字符在 diff/审查里就是隐形炸弹。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// JS `String.prototype.trim` / `\s` 的字符集(区别于 Dart trim:
/// 后者多剔 U+0085)。做成共享片段,空白判定与 WhitespaceSplit 必须同源。
const String _jsWs =
    '\t\n\u000B\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff';

class NaiT5Tokenizer {
  NaiT5Tokenizer._(
    this._ids,
    this._scores,
    this._unkId,
    this._unkScore,
    this._maxTokCp,
    this._added,
  );

  /// token 字符串 → id(词表 + added_tokens,同串同 id)。
  final Map<String, int> _ids;
  final List<double> _scores;
  final int _unkId;
  final double _unkScore;

  /// 词表 token 最长码点数,Viterbi 内层探测上界。
  final int _maxTokCp;

  /// added_tokens 字面量(`<pad>`/`</s>`/`<unk>`/`<extra_id_N>`),按 JSON 原序。
  final List<String> _added;

  /// RegExp 不随 isolate 传递,惰性重建。JSON 里 `<extra_id_99..90>` 排在
  /// `<extra_id_9>` 前,选择序天然最长优先,与 web 的字典树切分等价。
  RegExp? _addedReCache;
  RegExp get _addedRe =>
      _addedReCache ??= RegExp(_added.map(RegExp.escape).join('|'));

  /// web tokenizer.ts 同款缓存:满 1000 清先入的一半,读不提序。
  final Map<String, int> _cache = {};
  static const _maxCache = 1000;

  /// isolate 入口:解析 tokenizer JSON(HF tokenizers 格式)。
  static NaiT5Tokenizer parse(String jsonStr) {
    final root = jsonDecode(jsonStr) as Map<String, dynamic>;
    final model = root['model'] as Map<String, dynamic>;
    final rawVocab = model['vocab'] as List;
    final n = rawVocab.length;
    final ids = <String, int>{};
    final scores = List<double>.filled(n, 0);
    var minScore = double.infinity;
    var maxTokCp = 1;
    for (var i = 0; i < n; i++) {
      final entry = rawVocab[i] as List;
      final tok = entry[0] as String;
      final score = (entry[1] as num).toDouble();
      ids[tok] = i;
      scores[i] = score;
      if (score < minScore) minScore = score;
      final cp = tok.runes.length;
      if (cp > maxTokCp) maxTokCp = cp;
    }
    final unkId = model['unk_id'] as int;
    // JS 先对原始分取 min,再把 unk 位改写成 min-10。
    final unkScore = minScore - 10;
    scores[unkId] = unkScore;
    final added = <String>[];
    for (final a in root['added_tokens'] as List) {
      final m = a as Map<String, dynamic>;
      final content = m['content'] as String;
      added.add(content);
      ids[content] = m['id'] as int;
    }
    return NaiT5Tokenizer._(ids, scores, unkId, unkScore, maxTokCp, added);
  }

  // ---- web src/services/tokenizer.ts 的 countTokens ----

  static final _reBrackets = RegExp(r'[\[\]{}]');
  static final _reWeights = RegExp(r'-?\d*\.?\d*::');
  static final _reJsBlank = RegExp('^[$_jsWs]*\$');

  int countTokens(String text) {
    if (text.isEmpty || _reJsBlank.hasMatch(text)) return 0;
    final cached = _cache[text];
    if (cached != null) return cached;
    final normalized = text
        .replaceAll(_reBrackets, '')
        .replaceAll(_reWeights, '');
    if (_reJsBlank.hasMatch(normalized)) return _remember(text, 0);
    return _remember(text, _encodeCount(normalized));
  }

  int _remember(String text, int count) {
    if (_cache.length >= _maxCache) {
      for (final k in _cache.keys.take(_maxCache ~/ 2).toList()) {
        _cache.remove(k);
      }
    }
    _cache[text] = count;
    return count;
  }

  // ---- encode 管线(只算数目) ----

  int _encodeCount(String text) {
    var count = 0;
    var idx = 0;
    // added_token 字面量切分:命中的整只计 1,其余段走正常管线。
    for (final m in _addedRe.allMatches(text)) {
      count += _countSegment(text.substring(idx, m.start));
      count += 1;
      idx = m.end;
    }
    count += _countSegment(text.substring(idx));
    return count + 1; // TemplateProcessing:结尾 </s>
  }

  /// Precompiled 第一步:删控制符(JS 原样;注意不含 U+0000/U+0085)。
  static final _reControl = RegExp(
    '[\u0001-\u0008\u000B\u000E-\u001F\u007F\u008F\u009F]',
  );

  /// 第二步:空白类/零宽字符归一成空格(含 U+2581 本身与 U+FFFD;
  /// U+2000-200F 连零宽符/方向符一起吃掉 —— JS 原样)。
  static final _reWsLike = RegExp(
    '[\u0009\u000A\u000C\u000D\u00A0\u1680\u2000-\u200F'
    '\u2028\u2029\u202F\u205F\u2581\u3000\uFEFF\uFFFD]',
  );

  static String _normalize(String text) {
    final t = text.replaceAll(_reControl, '').replaceAll(_reWsLike, ' ');
    // JS quirk:全角波浪线 U+FF5E 被保护,其余分段各自 NFKC。
    if (t.contains('～')) {
      return t.split('～').map(unorm.nfkc).join('～');
    }
    return unorm.nfkc(t);
  }

  /// JS `\S+`(WhitespaceSplit)。
  static final _reNonWs = RegExp('[^$_jsWs]+');

  int _countSegment(String section) {
    if (section.isEmpty) return 0;
    final norm = _normalize(section);
    if (norm.isEmpty) return 0;
    final tokenIds = <int>[];
    for (final m in _reNonWs.allMatches(norm)) {
      // Metaspace:空格→U+2581,无前缀则补(prepend_scheme 'always')。
      var piece = m.group(0)!.replaceAll(' ', '▁');
      if (!piece.startsWith('▁')) piece = '▁$piece';
      _viterbiInto(piece, tokenIds);
    }
    // fuse_unk:每一段连续 unk 计 1(web 在 model._call 里对整段做)。
    var count = 0;
    var i = 0;
    while (i < tokenIds.length) {
      count++;
      if (tokenIds[i] != _unkId) {
        i++;
        continue;
      }
      while (++i < tokenIds.length && tokenIds[i] == _unkId) {}
    }
    return count;
  }

  /// Unigram Viterbi(镜像 JS TokenLattice/populate_nodes):
  /// 节点插入顺序 = 起点升序、同起点按匹配长度升序、unk 殿后;
  /// 松弛用严格大于,平分保留先插入者 —— 顺序就是语义的一部分,别重排。
  void _viterbiInto(String piece, List<int> out) {
    // 码点边界表:offs[i] 是第 i 个码点的 UTF-16 起点(探测按码点走,
    // 半个代理对不会成为候选边界)。
    final offs = <int>[];
    for (var i = 0; i < piece.length;) {
      offs.add(i);
      final c = piece.codeUnitAt(i);
      i += (c & 0xFC00) == 0xD800 && i + 1 < piece.length ? 2 : 1;
    }
    final n = offs.length;
    offs.add(piece.length);

    final begin = List.generate(n + 1, (_) => <_Node>[]);
    final end = List.generate(n + 1, (_) => <_Node>[]);
    final bos = _Node(-1, 0);
    end[0].add(bos);
    final eos = _Node(-1, 0);
    begin[n].add(eos);

    for (var b = 0; b < n; b++) {
      var hasSingle = false;
      final maxL = n - b < _maxTokCp ? n - b : _maxTokCp;
      for (var l = 1; l <= maxL; l++) {
        final id = _ids[piece.substring(offs[b], offs[b + l])];
        if (id == null) continue;
        final node = _Node(id, _scores[id]);
        begin[b].add(node);
        end[b + l].add(node);
        if (l == 1) hasSingle = true;
      }
      if (!hasSingle) {
        final node = _Node(_unkId, _unkScore);
        begin[b].add(node);
        end[b + 1].add(node);
      }
    }

    for (var pos = 0; pos <= n; pos++) {
      if (begin[pos].isEmpty) return; // JS 此处整段放弃(域内到不了)
      for (final r in begin[pos]) {
        var bestScore = 0.0;
        _Node? bestNode;
        for (final l in end[pos]) {
          final s = l.backtrace + r.score;
          if (bestNode == null || s > bestScore) {
            bestNode = l;
            bestScore = s;
          }
        }
        if (bestNode == null) return;
        r.prev = bestNode;
        r.backtrace = bestScore;
      }
    }

    // 回溯:eos.prev 起、bos(prev==null)止,反转即 token 序。
    final rev = <int>[];
    for (var cur = eos.prev; cur != null && cur.prev != null; cur = cur.prev) {
      rev.add(cur.tokenId);
    }
    out.addAll(rev.reversed);
  }
}

class _Node {
  _Node(this.tokenId, this.score);
  final int tokenId;
  final double score;
  _Node? prev;
  double backtrace = 0;
}

/// 词表 2.5MB,解析放 isolate;就绪前 UI 用 ÷2.2 估算顶一帧,就绪自动刷新。
final naiTokenizerProvider = FutureProvider<NaiT5Tokenizer>((ref) async {
  final s = await rootBundle.loadString('assets/t5_tokenizer.json');
  return compute(NaiT5Tokenizer.parse, s);
});

/// 生成页/编辑器的 x/512 读数 —— web totalTokenCount 口径:主串、启用角色串、
/// 激活预设各自独立计数(各含一枚 </s>)后相加,不是拼接后整体计数。
/// [tok] 传 `ref.watch(naiTokenizerProvider).value`,未就绪时退回旧粗估。
int totalPromptTokens(
  NaiT5Tokenizer? tok, {
  required String main,
  List<String> parts = const [],
  String preset = '',
}) {
  if (tok == null) {
    final joined = [
      for (final s in [preset, main, ...parts])
        if (s.trim().isNotEmpty) s,
    ].join(', ');
    return (joined.length / 2.2).round().clamp(0, 999);
  }
  var n = tok.countTokens(main);
  for (final p in parts) {
    n += tok.countTokens(p);
  }
  n += tok.countTokens(preset);
  return n;
}
