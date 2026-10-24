import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/store/atomic_file.dart';
import '../../core/util/log.dart';
import 'canvas_models.dart';
import 'workspace_store.dart';

/// 一次出图记下的画布内容,和这次出的图。
class CanvasHistoryEntry {
  CanvasHistoryEntry({
    required this.id,
    required this.at,
    required this.json,
    required this.preview,
    required this.resultIds,
    required this.refs,
  }) : fingerprint = jsonEncode(json);

  final String id;

  /// 最近一次用这组内容出图的时间(毫秒)。
  final int at;

  /// 画布内容,格式同存档里的 `canvases[].prompts`;图片只记哈希。
  final Map<String, dynamic> json;

  /// 不带图片的那份内容,列表里看词和参数用。
  final CanvasPrompts preview;

  /// 这组内容出的图(图库 id),新的在前,最多 [CanvasHistoryStore.maxResults] 张。
  final List<String> resultIds;

  /// [json] 引用的 blob 哈希。
  final List<String> refs;

  final String fingerprint;

  /// [json] 里某个列表键的条数(Vibe、角色参考等,[preview] 里没有图片那几项)。
  int countOf(String key) => json[key] is List ? (json[key] as List).length : 0;

  bool has(String key) => json[key] is Map;

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at,
    'content': json,
    'results': resultIds,
    'refs': refs,
  };
}

/// 画布历史(`<support>/workspace/history/<画布 id>.json`):每张画布记最近
/// [cap] 次出图时的内容,内容和上一条一样就只把新图追加到那一条。
///
/// 删掉的画布文件先留着(删除可撤销),启动时由 [removeOrphans] 清掉。
class CanvasHistoryStore {
  CanvasHistoryStore(this._workspace, Directory supportRoot)
    : _dir = Directory('${supportRoot.path}/workspace/history');

  static const cap = 50;
  static const maxResults = 4;

  final WorkspaceStore _workspace;
  final Directory _dir;
  final _cache = <String, List<CanvasHistoryEntry>>{};
  Future<void> _chain = Future.value();
  var _seq = 0;

  File _fileOf(String canvasId) => File('${_dir.path}/$canvasId.json');

  /// 新的在前。
  Future<List<CanvasHistoryEntry>> load(String canvasId) async {
    final cached = _cache[canvasId];
    if (cached != null) return cached;
    final out = <CanvasHistoryEntry>[];
    try {
      final f = _fileOf(canvasId);
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map && j['entries'] is List) {
          for (final e in j['entries'] as List) {
            if (e is! Map ||
                e['id'] is! String ||
                e['content'] is! Map<String, dynamic>) {
              continue;
            }
            final content = e['content'] as Map<String, dynamic>;
            out.add(
              CanvasHistoryEntry(
                id: e['id'] as String,
                at: (e['at'] as num?)?.toInt() ?? 0,
                json: content,
                preview: await _workspace.decodeCanvas(
                  content,
                  withImages: false,
                ),
                resultIds: _strings(e['results']),
                refs: _strings(e['refs']),
              ),
            );
          }
        }
      }
    } catch (e) {
      logd('[history] 读取失败: $e');
    }
    return _cache[canvasId] ??= out;
  }

  static List<String> _strings(Object? raw) => [
    if (raw is List)
      for (final s in raw)
        if (s is String) s,
  ];

  /// 记一次出图:[content] 是发起时那张画布的内容,[resultIds] 是这次入库的图。
  Future<void> record(
    String canvasId,
    CanvasPrompts content,
    List<String> resultIds,
  ) => _chain = _chain.then((_) async {
    try {
      final enc = await _workspace.encodeCanvas(content);
      final json = jsonDecode(jsonEncode(enc.json)) as Map<String, dynamic>;
      final list = [...await load(canvasId)];
      final now = DateTime.now().millisecondsSinceEpoch;
      final head = list.firstOrNull;
      if (head != null && head.fingerprint == jsonEncode(json)) {
        list[0] = CanvasHistoryEntry(
          id: head.id,
          at: now,
          json: head.json,
          preview: head.preview,
          resultIds: [
            ...resultIds,
            ...head.resultIds.where((id) => !resultIds.contains(id)),
          ].take(maxResults).toList(),
          refs: head.refs,
        );
      } else {
        list.insert(
          0,
          CanvasHistoryEntry(
            id: 'h$now-${_seq++}',
            at: now,
            json: json,
            preview: await _workspace.decodeCanvas(json, withImages: false),
            resultIds: resultIds.take(maxResults).toList(),
            refs: enc.refs.toList(),
          ),
        );
        if (list.length > cap) list.removeRange(cap, list.length);
      }
      _cache[canvasId] = list;
      await writeStringAtomic(
        _fileOf(canvasId),
        jsonEncode({
          'v': 1,
          'entries': [for (final e in list) e.toJson()],
        }),
      );
    } catch (e) {
      logd('[history] 记录失败: $e');
    }
  });

  Future<void> get idle => _chain;

  /// 所有历史引用的 blob 哈希(blob GC 的引用清单)。
  Future<Set<String>> liveRefs() async {
    await _chain;
    final out = <String>{};
    try {
      if (!await _dir.exists()) return out;
      await for (final f in _dir.list()) {
        if (f is! File || !f.path.endsWith('.json')) continue;
        try {
          final j = jsonDecode(await f.readAsString());
          if (j is! Map || j['entries'] is! List) continue;
          for (final e in j['entries'] as List) {
            if (e is Map) out.addAll(_strings(e['refs']));
          }
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// 删掉不在 [keep] 里的画布的历史;[since] 之后才写的不动(本次启动新建的画布)。
  Future<void> removeOrphans(Set<String> keep, DateTime since) async {
    try {
      if (!await _dir.exists()) return;
      await for (final f in _dir.list()) {
        if (f is! File || !f.path.endsWith('.json')) continue;
        final name = f.uri.pathSegments.last;
        final id = name.substring(0, name.length - '.json'.length);
        if (keep.contains(id)) continue;
        if ((await f.stat()).modified.isAfter(since)) continue;
        _cache.remove(id);
        await f.delete();
      }
    } catch (_) {}
  }
}

/// 一张画布的历史,新的在前。记了新的一条就由记录方 invalidate。
final canvasHistoryProvider = FutureProvider.autoDispose
    .family<List<CanvasHistoryEntry>, String>(
      (ref, canvasId) => ref.watch(appStoresProvider).history.load(canvasId),
    );
