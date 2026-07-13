import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/auth/bot_session_store.dart';
import '../../../core/net/backend_config.dart';
import 'completion_source.dart';
import 'suggestions.dart';

/// 注音层的后端翻译通道(仅增强补全模式),对齐 web `translate.ts` 三步:
/// ① `POST /api/tags/translations/lookup` 共享翻译库(公开,内存镜像,轻)
/// ② 未命中批量走 `POST /api/translate/en2zh` 服务端 LLM(公开,60/min/IP 限流)
/// ③ LLM 产出 fire-and-forget `POST /api/tags/translations/submit` 回写共享库
///    (「登录」= Bearer bot session;无会话跳过)
/// 命中回填 [cacheTagMeta](transCacheRev 随之自增)后 notifyListeners,
/// 编辑器刷新注音层/词条栏。离线补全模式不联网(enabled=false 全程 no-op)。
class TagTranslationService extends ChangeNotifier {
  TagTranslationService({
    required this.enabled,
    required this.baseUrl,
    this.sessionId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final bool enabled;
  final String baseUrl;
  final String? sessionId;
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);
  static const _batchMax = 20; // en2zh 一次 LLM 调用里的 tag 数上限

  final _pending = <String>{}; // 待查(小写、空格形式)
  final _asked = <String>{}; // 已有定论(含 LLM 也答不出的),本进程不再问
  Timer? _timer;
  bool _busy = false;
  DateTime? _llmCooldownUntil; // LLM 失败/限流后的冷却窗口

  /// 值得问后端的名字:含英文字母(纯中文/数字/符号跳过)、非画师前缀、长度合理。
  static bool _worthAsking(String name) {
    if (name.isEmpty || name.length > 60) return false;
    if (name.contains('artist:')) return false;
    return name.codeUnits.any(
      (c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A),
    );
  }

  /// 编辑器解析后把注音未命中的名字塞进来;防抖攒批后查询。
  void request(Iterable<String> names) {
    if (!enabled || baseUrl.isEmpty) return;
    var added = false;
    for (final n in names) {
      final k = n.trim().toLowerCase();
      if (!_worthAsking(k) || _asked.contains(k)) continue;
      if (translationOf(k) != null) continue; // 本地缓存/词库已有
      added |= _pending.add(k);
    }
    if (added && !_busy) _arm(const Duration(milliseconds: 700));
  }

  void _arm(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, _flush);
  }

  Future<void> _flush() async {
    if (_busy || _pending.isEmpty) return;
    _busy = true;
    final batch = _pending.take(_batchMax).toList();
    _pending.removeAll(batch);
    try {
      // ① 共享翻译库
      final Map<String, String> found;
      try {
        found = await _lookup(batch);
      } catch (_) {
        // 网络失败:整批放回,稍后再试(避免疯狂重试)
        _pending.addAll(batch);
        _arm(const Duration(seconds: 30));
        return;
      }
      found.forEach((tag, zh) {
        cacheTagMeta(tag, trans: zh);
        _asked.add(tag);
      });

      final missing = [
        for (final t in batch)
          if (!found.containsKey(t)) t,
      ];
      var gotAny = found.isNotEmpty;

      // ② 服务端 LLM(冷却窗口内先搁置)
      if (missing.isNotEmpty) {
        final until = _llmCooldownUntil;
        if (until != null && DateTime.now().isBefore(until)) {
          _pending.addAll(missing);
          _arm(until.difference(DateTime.now()) + const Duration(seconds: 1));
        } else {
          final ai = await _en2zh(missing);
          if (ai == null) {
            _llmCooldownUntil = DateTime.now().add(const Duration(seconds: 90));
            _pending.addAll(missing);
            _arm(const Duration(seconds: 91));
          } else {
            final entries = <Map<String, String>>[];
            for (var i = 0; i < missing.length; i++) {
              final zh = i < ai.length ? ai[i].trim() : '';
              _asked.add(missing[i]); // LLM 给不出的也不再问
              if (zh.isNotEmpty && zh.toLowerCase() != missing[i]) {
                cacheTagMeta(missing[i], trans: zh);
                entries.add({'tag': missing[i], 'zh': zh, 'source': 'ai'});
                gotAny = true;
              }
            }
            _submit(entries); // ③ 回写共享库,不等结果
          }
        }
      }

      if (gotAny) notifyListeners();
    } finally {
      _busy = false;
      if (_pending.isNotEmpty && (_timer == null || !_timer!.isActive)) {
        _arm(const Duration(milliseconds: 400));
      }
    }
  }

  // 键标准化对齐后端:小写 + 空格→下划线;响应键映射回空格形式回填。
  Future<Map<String, String>> _lookup(List<String> tags) async {
    final norm = {for (final t in tags) t.replaceAll(' ', '_'): t};
    final r = await _client
        .post(
          Uri.parse('$baseUrl/api/tags/translations/lookup'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'tags': [...norm.keys],
          }),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) return const {};
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) return const {};
    return {
      for (final e in j.entries)
        if (norm[e.key] != null &&
            e.value is String &&
            (e.value as String).isNotEmpty)
          norm[e.key]!: e.value as String,
    };
  }

  /// LLM 英译中(web translateSegments 同款指令与解析);失败返回 null。
  Future<List<String>?> _en2zh(List<String> tags) async {
    final instruction =
        '你是Danbooru标签翻译器,负责将Danbooru/NovelAI绘画标签从英文翻译为中文。\n'
        '这些标签用于AI绘画(Stable Diffusion/NovelAI),请在绘画语境下理解含义。\n'
        '翻译要求:\n'
        '1. 简洁准确,符合绘画标签的含义(如 "1girl" → "1个女孩","masterpiece" → "杰作")\n'
        '2. 角色名、画师名(artist:xxx)等专有名词保持原样不翻译\n'
        '3. 身体部位、服装、姿势等按绘画描述语境翻译\n'
        '4. 返回格式必须是JSON数组,顺序与输入一致\n\n'
        'Input: ${jsonEncode(tags)}\n\n'
        '只返回JSON数组,不要其他内容。';
    try {
      final r = await _client
          .post(
            Uri.parse('$baseUrl/api/translate/en2zh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'messages': [
                {'role': 'user', 'content': instruction},
              ],
              'temperature': 0.3,
              'max_tokens': 1500,
            }),
          )
          .timeout(_timeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      var content = '';
      final choices = (j as Map)['choices'];
      if (choices is List && choices.isNotEmpty) {
        final msg = (choices.first as Map)['message'];
        if (msg is Map) content = (msg['content'] as String?) ?? '';
      }
      return _parseJsonArray(content);
    } catch (_) {
      return null;
    }
  }

  /// 剥 markdown 代码块后解析 JSON 数组(web parseJsonArray 同款容错)。
  static List<String>? _parseJsonArray(String text) {
    var s = text.trim();
    s = s
        .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*```$'), '');
    List<String>? tryParse(String x) {
      try {
        final a = jsonDecode(x);
        return a is List ? [for (final v in a) '$v'] : null;
      } catch (_) {
        return null;
      }
    }

    final direct = tryParse(s);
    if (direct != null) return direct;
    final m = RegExp(r'\[[\s\S]*?\]').firstMatch(s);
    return m == null ? null : tryParse(m.group(0)!);
  }

  /// 回写共享库(fire-and-forget;需登录,无 bot 会话或失败都静默)。
  void _submit(List<Map<String, String>> entries) {
    final sid = sessionId;
    if (entries.isEmpty || sid == null || sid.isEmpty) return;
    _client
        .post(
          Uri.parse('$baseUrl/api/tags/translations/submit'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $sid',
          },
          body: jsonEncode({'entries': entries}),
        )
        .timeout(_timeout)
        .then((_) {}, onError: (_) {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }
}

/// 按生效来源 + 后端基址 + 会话构造;任一变化即重建(与 tagCompletionProvider 同款)。
final tagTranslationServiceProvider = Provider<TagTranslationService>((ref) {
  final source = ref.watch(effectiveCompletionSourceProvider);
  final base = ref.watch(backendBaseProvider).value ?? '';
  final sid = ref.watch(botSessionProvider).value?.sessionId;
  final s = TagTranslationService(
    enabled: source == CompletionSource.enhanced,
    baseUrl: base,
    sessionId: sid,
  );
  ref.onDispose(s.dispose);
  return s;
});
