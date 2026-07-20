import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/store/blob_store.dart';
import '../../core/util/image_ops.dart';
import '../generate/models.dart' show GenerateState;
import '../generate/state_codec.dart';
import 'models.dart';

/// 图库持久化(`<support>/gallery/`):每张结果 `images/<id>.png` 原图 +
/// `thumbs/<id>.png` 缩略图 + `inputs/<id>.json` 参数快照(参考图外置
/// blob 仓),旁挂 index.json(顺序/选中/发号器)。启动只读索引,像素
/// 按需懒读——重启不丢图,也不把整库塞回内存。
class GalleryStore {
  GalleryStore(this._blobs, Directory supportRoot)
      : _root = Directory('${supportRoot.path}/gallery');

  final BlobStore _blobs;
  final Directory _root;

  Directory get _imagesDir => Directory('${_root.path}/images');
  Directory get _thumbsDir => Directory('${_root.path}/thumbs');
  Directory get _inputsDir => Directory('${_root.path}/inputs');
  File get _indexFile => File('${_root.path}/index.json');

  File _imageFile(String id) => File('${_imagesDir.path}/$id.png');
  File _thumbFile(String id) => File('${_thumbsDir.path}/$id.png');
  File _inputFile(String id) => File('${_inputsDir.path}/$id.json');

  /// 启动读出的图库(字节/快照皆空壳,懒读);首启为空。
  List<ResultImage> initialResults = const [];
  String? initialSelectedId;
  int seq = 0;

  static final _seqRe = RegExp(r'^gen(\d+)$');

  Future<void> load() async {
    try {
      await _imagesDir.create(recursive: true);
      await _thumbsDir.create(recursive: true);
      await _inputsDir.create(recursive: true);
      if (!await _indexFile.exists()) return;
      final j = jsonDecode(await _indexFile.readAsString());
      if (j is! Map) return;
      seq = (j['seq'] as num?)?.toInt() ?? 0;
      initialSelectedId = j['selectedId'] as String?;
      if (j['items'] is List) {
        final out = <ResultImage>[];
        for (final e in j['items'] as List) {
          if (e is! Map || e['id'] is! String) continue;
          final id = e['id'] as String;
          ResultBadge badge = ResultBadge.none;
          for (final b in ResultBadge.values) {
            if (b.name == e['badge']) badge = b;
          }
          out.add(ResultImage(
            id: id,
            width: (e['w'] as num?)?.toInt() ?? 0,
            height: (e['h'] as num?)?.toInt() ?? 0,
            seed: (e['seed'] as num?)?.toInt() ?? 0,
            badge: badge,
            hasInput: e['hasInput'] == true,
          ));
          // 索引防抖窗口内被杀时 seq 可能落后于条目 id,取最大防撞车
          final m = _seqRe.firstMatch(id);
          if (m != null) {
            final n = int.parse(m.group(1)!) + 1;
            if (n > seq) seq = n;
          }
        }
        initialResults = List.unmodifiable(out);
      }
    } catch (e) {
      debugPrint('[gallery-store] 索引载入失败(按空库处理): $e');
      initialResults = const [];
      initialSelectedId = null;
    }
  }

  // ---- 写入(串行队列,互不重叠) ----

  Future<void> _chain = Future.value();

  /// 写入队列排空(存储管理在清空后等它,再做 GC/重扫)。
  Future<void> get idle => _chain;

  void _enqueue(Future<void> Function() job) {
    _chain = _chain.then((_) => job()).catchError((Object e) {
      debugPrint('[gallery-store] 写入失败: $e');
    });
  }

  /// 新结果落盘:原图 + 缩略图 + 参数快照(有则)。
  /// 调用时机是 addResult 同帧,bytes/input 一定在内存里。
  void persistResult(ResultImage r) {
    final bytes = r.bytes;
    if (bytes == null) return;
    final input = r.input;
    _enqueue(() async {
      await _imageFile(r.id).writeAsBytes(bytes);
      try {
        await _thumbFile(r.id)
            .writeAsBytes(await coverResizePng(bytes, 256, 256));
      } catch (_) {} // 缩略图失败不阻断,读取端退回原图
      if (input != null) {
        final enc = await encodeGenerateState(input, _blobs);
        await _inputFile(r.id).writeAsString(jsonEncode({
          'v': 1,
          'refs': enc.refs.toList(),
          'state': enc.json,
        }));
      }
    });
  }

  // 索引防抖:新增/点选共用,窗口内合并成一次全量重写
  Timer? _idxTimer;
  List<ResultImage>? _idxItems;
  String? _idxSelected;
  int _idxSeq = 0;

  void scheduleIndex({
    required List<ResultImage> results,
    required String? selectedId,
    required int seq,
  }) {
    _idxItems = results;
    _idxSelected = selectedId;
    _idxSeq = seq;
    _idxTimer?.cancel();
    _idxTimer = Timer(const Duration(milliseconds: 400), flushIndex);
  }

  /// 立即写索引(前后台切换时由 AppStores.flushNow 调用)。
  void flushIndex() {
    final items = _idxItems;
    if (items == null) return;
    _idxItems = null;
    _idxTimer?.cancel();
    final selected = _idxSelected;
    final seq = _idxSeq;
    _enqueue(() async {
      await _indexFile.writeAsString(jsonEncode({
        'v': 1,
        'seq': seq,
        'selectedId': ?selected,
        'items': [
          for (final r in items)
            {
              'id': r.id,
              'w': r.width,
              'h': r.height,
              'seed': r.seed,
              'badge': r.badge.name,
              'hasInput': r.hasInput,
            },
        ],
      }));
    });
  }

  /// 删除若干条结果的文件(上限裁剪用):原图/缩略图/快照一并删。
  /// 索引由调用方随后 scheduleIndex 重写。
  void deleteResultFiles(List<String> ids) {
    if (ids.isEmpty) return;
    _enqueue(() async {
      for (final id in ids) {
        for (final f in [_imageFile(id), _thumbFile(id), _inputFile(id)]) {
          try {
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
    });
  }

  /// 清空图库文件(存储管理「清空图库」):删光原图/缩略图/快照,
  /// 写空索引但**保留发号器**(id 永不复用)。作废挂起的索引写,
  /// 串行队列保证在途的 persistResult 先完成再删。
  void clearAllFiles({required int seq}) {
    _idxItems = null;
    _idxTimer?.cancel();
    _enqueue(() async {
      for (final d in [_imagesDir, _thumbsDir, _inputsDir]) {
        try {
          await for (final ent in d.list()) {
            try {
              await ent.delete(recursive: true);
            } catch (_) {}
          }
        } catch (_) {}
      }
      await _indexFile.writeAsString(
        jsonEncode({'v': 1, 'seq': seq, 'items': const <Object>[]}),
      );
    });
  }

  // ---- 懒读 ----

  Future<Uint8List?> readImage(String id) async {
    try {
      final f = _imageFile(id);
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 缩略图;缺失(旧数据/生成失败)退回原图。
  Future<Uint8List?> readThumb(String id) async {
    try {
      final f = _thumbFile(id);
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return readImage(id);
  }

  /// 参数快照(重新生成/重绘/导入用),blob 缺失字段按可用降级。
  Future<GenerateState?> readInput(String id) async {
    try {
      final f = _inputFile(id);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['state'] is! Map<String, dynamic>) return null;
      return await decodeGenerateState(
        j['state'] as Map<String, dynamic>,
        _blobs,
      );
    } catch (e) {
      debugPrint('[gallery-store] 快照读取失败 $id: $e');
      return null;
    }
  }

  /// 全部参数快照引用的 blob 哈希(启动 GC 的引用清单)。
  Future<Set<String>> liveRefs() async {
    final out = <String>{};
    try {
      await for (final ent in _inputsDir.list()) {
        if (ent is! File || !ent.path.endsWith('.json')) continue;
        try {
          final j = jsonDecode(await ent.readAsString());
          if (j is Map && j['refs'] is List) {
            for (final r in j['refs'] as List) {
              if (r is String) out.add(r);
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }
}
