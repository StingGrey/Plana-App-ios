import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/util/image_ops.dart';
import '../generate/vibe_cache.dart';
import 'naiv4vibe_codec.dart';

/// 顶层函数:后台 isolate 算图片字节哈希(编码缓存的内容寻址键)。
String sha256HexOfBytes(Uint8List bytes) => sha256.convert(bytes).toString();

/// 库索引条目(轻量,列表页只碰它和缩略图,不 parse 大 JSON)。
class VibeEntry {
  const VibeEntry({
    required this.id,
    required this.name,
    required this.fileName,
    this.imageHash,
    this.hasImage = true,
    this.defaultStrength,
    this.defaultInfoExtracted,
    this.supportedModels = const [],
    this.tags = const [],
    this.createdAt = 0,
    this.lastUsedAt = 0,
    this.sizeBytes = 0,
    this.originFilename,
  });

  /// NAI 官方 vibe id(SHA256 of base64 文本);纯编码文件为其自带 id。
  final String id;
  final String name;

  /// files/ 目录下的文件名。
  final String fileName;

  /// 原图**字节**哈希(编码缓存键);纯编码 vibe 为 null。
  final String? imageHash;
  final bool hasImage;

  final double? defaultStrength;
  final double? defaultInfoExtracted;

  /// 文件自带 encodings 的模型键(v4-5full 等,徽标展示用;
  /// 缓存里后续新增的编码不回填这里,详情页实时合并)。
  final List<String> supportedModels;

  final List<String> tags;
  final int createdAt;
  final int lastUsedAt; // 0 = 未用过
  final int sizeBytes;

  /// 公共库来源文件名(仅从公共库收藏的条目有);app 私有关联,只存 index.json,
  /// 索引重建时会丢失(仅影响公共 tab 的「已收藏」标记,不影响功能)。
  final String? originFilename;

  VibeEntry copyWith({
    String? name,
    double? defaultStrength,
    double? defaultInfoExtracted,
    List<String>? tags,
    int? lastUsedAt,
    int? sizeBytes,
    List<String>? supportedModels,
    String? originFilename,
  }) =>
      VibeEntry(
        id: id,
        name: name ?? this.name,
        fileName: fileName,
        imageHash: imageHash,
        hasImage: hasImage,
        defaultStrength: defaultStrength ?? this.defaultStrength,
        defaultInfoExtracted: defaultInfoExtracted ?? this.defaultInfoExtracted,
        supportedModels: supportedModels ?? this.supportedModels,
        tags: tags ?? this.tags,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        originFilename: originFilename ?? this.originFilename,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'fileName': fileName,
        if (imageHash != null) 'imageHash': imageHash,
        'hasImage': hasImage,
        if (defaultStrength != null) 'defaultStrength': defaultStrength,
        if (defaultInfoExtracted != null)
          'defaultInfoExtracted': defaultInfoExtracted,
        'supportedModels': supportedModels,
        'tags': tags,
        'createdAt': createdAt,
        'lastUsedAt': lastUsedAt,
        'sizeBytes': sizeBytes,
        if (originFilename != null) 'originFilename': originFilename,
      };

  static VibeEntry? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final fileName = j['fileName'];
    if (id is! String || fileName is! String) return null;
    return VibeEntry(
      id: id,
      name: j['name'] is String ? j['name'] as String : '',
      fileName: fileName,
      imageHash: j['imageHash'] as String?,
      hasImage: j['hasImage'] != false,
      defaultStrength: (j['defaultStrength'] as num?)?.toDouble(),
      defaultInfoExtracted: (j['defaultInfoExtracted'] as num?)?.toDouble(),
      supportedModels: j['supportedModels'] is List
          ? [for (final m in j['supportedModels'] as List) if (m is String) m]
          : const [],
      tags: j['tags'] is List
          ? [for (final t in j['tags'] as List) if (t is String) t]
          : const [],
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      lastUsedAt: (j['lastUsedAt'] as num?)?.toInt() ?? 0,
      sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
      originFilename: j['originFilename'] as String?,
    );
  }
}

/// 从库条目取出的「可生成」数据(添加到生成面板用)。
typedef VibeForGenerate = ({
  Uint8List? image,
  String? imageHash,
  Map<String, String>? encodedByModel,
  double fixedInfoExtracted,
});

/// Vibe 库:`<support>/vibe_library/` 下每条 vibe 一个标准 .naiv4vibe 文件
/// (文件即真相,与 NAI 官方/web 端互通),旁挂 index.json + thumbs/ 供列表页;
/// 索引损坏时从文件全量重建。编码不存这里——唯一真相是内容寻址缓存
/// [vibeCacheProvider],导入时灌入、导出时收集。
final vibeLibraryProvider =
    AsyncNotifierProvider<VibeLibrary, List<VibeEntry>>(VibeLibrary.new);

class VibeLibrary extends AsyncNotifier<List<VibeEntry>> {
  late Directory _root;

  Directory get _filesDir => Directory('${_root.path}/files');
  Directory get _thumbsDir => Directory('${_root.path}/thumbs');
  File get _indexFile => File('${_root.path}/index.json');

  File fileOf(VibeEntry e) => File('${_filesDir.path}/${e.fileName}');

  /// 缩略图文件(可能不存在,UI 用 errorBuilder/占位兜底)。
  File thumbOf(VibeEntry e) => File('${_thumbsDir.path}/${_safeName(e.id)}.png');

  @override
  Future<List<VibeEntry>> build() async {
    final sup = await getApplicationSupportDirectory();
    _root = Directory('${sup.path}/vibe_library');
    await _filesDir.create(recursive: true);
    await _thumbsDir.create(recursive: true);
    try {
      if (await _indexFile.exists()) {
        final j = jsonDecode(await _indexFile.readAsString());
        if (j is Map && j['entries'] is List) {
          return [
            for (final e in j['entries'] as List)
              if (e is Map<String, dynamic>)
                if (VibeEntry.fromJson(e) case final VibeEntry v) v,
          ];
        }
      }
    } catch (_) {
      // 索引损坏 → 从文件重建
    }
    return _rebuildFromFiles();
  }

  // ---- 内部 ----

  static String _safeName(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  List<VibeEntry> get _entries => state.value ?? const [];

  VibeEntry? _byId(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 按公共库来源文件名查已收藏条目(公共 tab 判断「已收藏/已加入」)。
  VibeEntry? entryByOriginFilename(String filename) {
    for (final e in _entries) {
      if (e.originFilename == filename) return e;
    }
    return null;
  }

  Future<void> _setEntries(List<VibeEntry> list) async {
    state = AsyncData(List.unmodifiable(list));
    try {
      await _indexFile.writeAsString(
        jsonEncode({
          'version': 1,
          'entries': [for (final e in list) e.toJson()],
        }),
      );
    } catch (e) {
      debugPrint('[vibe-lib] 写索引失败: $e'); // 内存态仍可用,下次启动会重建
    }
  }

  Future<void> _writeThumb(String id, Uint8List pngBytes) async {
    try {
      await File('${_thumbsDir.path}/${_safeName(id)}.png').writeAsBytes(pngBytes);
    } catch (_) {}
  }

  /// 解析条目的最终库 id(文件自带 id 优先,无则由图推导/时间戳兜底)。
  static String idOfParsed(ParsedVibe p) => p.id.isNotEmpty
      ? p.id
      : (p.imageBase64 != null
          ? naiVibeIdOfBase64(p.imageBase64!)
          : 'enc_${DateTime.now().millisecondsSinceEpoch}');

  /// 由解析结果组装索引条目并落缩略图。
  /// 有原图时缩略图一律从原图现生成(导入文件的 thumbnail 可能是截断伪图)。
  Future<VibeEntry> _entryFromParsed(
    ParsedVibe p, {
    required String id,
    required String fileName,
    required int sizeBytes,
    String fallbackName = '',
    String? originFilename,
    VibeEntry? existing,
  }) async {
    final img = p.imageBase64;
    String? hash;
    if (img != null) {
      final bytes = base64Decode(img);
      hash = await compute(sha256HexOfBytes, bytes);
      try {
        await _writeThumb(id, await coverResizePng(bytes, 256, 256));
      } catch (_) {}
    } else {
      final t = p.thumbnailDataUrl;
      if (t != null) {
        try {
          await _writeThumb(id, base64Decode(t.split(',').last));
        } catch (_) {}
      }
    }
    final name = p.name.isNotEmpty
        ? p.name
        : (fallbackName.isNotEmpty ? fallbackName : '未命名 Vibe');
    return VibeEntry(
      id: id,
      name: name,
      fileName: fileName,
      imageHash: hash,
      hasImage: img != null,
      defaultStrength: p.defaultStrength ?? existing?.defaultStrength,
      defaultInfoExtracted: p.defaultInfoExtracted ?? existing?.defaultInfoExtracted,
      supportedModels: p.supportedModelKeys,
      tags: p.tags.isNotEmpty ? p.tags : (existing?.tags ?? const []),
      createdAt: existing?.createdAt ??
          (p.createdAt > 0 ? p.createdAt : DateTime.now().millisecondsSinceEpoch),
      lastUsedAt: existing?.lastUsedAt ?? 0,
      sizeBytes: sizeBytes,
      originFilename: originFilename ?? existing?.originFilename,
    );
  }

  /// 把文件自带的编码灌进内容寻址缓存(有原图哈希才有键;无 params 的条目
  /// 定位不了 IE,留在文件里不进缓存,导出时仍保留)。
  Future<void> _seedEncodings(ParsedVibe p, String? imageHash) async {
    if (imageHash == null) return;
    final cache = await ref.read(vibeCacheProvider.future);
    for (final it in p.encodingItems) {
      final ie = it.infoExtracted;
      if (ie == null) continue;
      await cache.put(imageHash, it.modelKey, ie, it.encoding);
    }
  }

  Future<List<VibeEntry>> _rebuildFromFiles() async {
    final out = <VibeEntry>[];
    try {
      await for (final ent in _filesDir.list()) {
        if (ent is! File || !ent.path.endsWith('.naiv4vibe')) continue;
        try {
          final text = await ent.readAsString();
          final parsed = parseVibeFileText(text);
          if (parsed.isEmpty) continue;
          final p = parsed.first;
          final e = await _entryFromParsed(
            p,
            id: idOfParsed(p),
            fileName: ent.uri.pathSegments.last,
            sizeBytes: text.length,
          );
          await _seedEncodings(p, e.imageHash);
          out.add(e);
        } catch (err) {
          debugPrint('[vibe-lib] 重建跳过 ${ent.path}: $err');
        }
      }
      out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      await _indexFile.writeAsString(jsonEncode({
        'version': 1,
        'entries': [for (final e in out) e.toJson()],
      }));
    } catch (e) {
      debugPrint('[vibe-lib] 重建失败: $e');
    }
    return out;
  }

  Future<void> _upsert(VibeEntry e) async {
    final list = [..._entries];
    final i = list.indexWhere((x) => x.id == e.id);
    if (i >= 0) {
      list[i] = e;
    } else {
      list.insert(0, e);
    }
    await _setEntries(list);
  }

  // ---- 导入 ----

  /// 图片入库(生成页导入顺手入库/库页导入图片共用)。
  /// 同 id(同图)已在库中时直接返回既有条目,不重复建档。
  /// [knownHash]:调用方已算好的字节哈希(生成页导入时避免重复计算)。
  Future<VibeEntry> importImageBytes(
    Uint8List bytes,
    String name, {
    String? knownHash,
  }) async {
    await future;
    final b64 = base64Encode(bytes);
    final id = naiVibeIdOfBase64(b64);
    final dup = _byId(id);
    if (dup != null) return dup;

    final hash = knownHash ?? await compute(sha256HexOfBytes, bytes);
    final thumb = await coverResizePng(bytes, 256, 256);
    final raw = newImageVibeRaw(
      imageBase64: b64,
      name: name.isEmpty ? '未命名 Vibe' : name,
      thumbnailDataUrl: 'data:image/png;base64,${base64Encode(thumb)}',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final fileName = '${_safeName(id)}.naiv4vibe';
    final text = jsonEncode(raw);
    await File('${_filesDir.path}/$fileName').writeAsString(text);
    await _writeThumb(id, thumb);

    final entry = VibeEntry(
      id: id,
      name: name.isEmpty ? '未命名 Vibe' : name,
      fileName: fileName,
      imageHash: hash,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      sizeBytes: text.length,
    );
    await _upsert(entry);
    return entry;
  }

  /// 导入 .naiv4vibe / .naiv4vibebundle 文本;返回落库的条目。
  /// 文件原样落盘(未知字段保留),自带编码灌入缓存(导入即免编码)。
  /// [originFilename]:公共库来源文件名(仅单条从公共库收藏时传)。
  /// 格式不对抛 [FormatException]。
  Future<List<VibeEntry>> importVibeText(
    String text, {
    String fallbackName = '',
    String? originFilename,
  }) async {
    await future;
    final parsed = parseVibeFileText(text);
    final out = <VibeEntry>[];
    var n = 0;
    for (final p in parsed) {
      final singleText = jsonEncode(p.raw);
      final id = p.id.isNotEmpty
          ? p.id
          : (p.imageBase64 != null
              ? naiVibeIdOfBase64(p.imageBase64!)
              : 'enc_${DateTime.now().millisecondsSinceEpoch}_$n');
      final fileName = '${_safeName(id)}.naiv4vibe';
      await File('${_filesDir.path}/$fileName').writeAsString(singleText);
      final existing = _byId(id);
      final entry = await _entryFromParsed(
        p,
        id: id,
        fileName: fileName,
        sizeBytes: singleText.length,
        fallbackName: fallbackName,
        originFilename: parsed.length == 1 ? originFilename : null,
        existing: existing,
      );
      await _seedEncodings(p, entry.imageHash);
      await _upsert(entry);
      out.add(entry);
      n++;
    }
    return out;
  }

  // ---- 导出 ----

  /// 单条导出为 .naiv4vibe 文本:文件本体 + 缓存里该图的全部编码合并。
  Future<String> exportText(VibeEntry e) async {
    final raw = await _readRawMerged(e);
    return jsonEncode(raw);
  }

  /// 多条打包为 .naiv4vibebundle 文本。
  Future<String> exportBundleText(List<VibeEntry> entries) async {
    final raws = <Map<String, dynamic>>[];
    for (final e in entries) {
      raws.add(await _readRawMerged(e));
    }
    return buildBundleText(raws);
  }

  Future<Map<String, dynamic>> _readRawMerged(VibeEntry e) async {
    final raw =
        jsonDecode(await fileOf(e).readAsString()) as Map<String, dynamic>;
    final hash = e.imageHash;
    if (hash != null) {
      final cache = await ref.read(vibeCacheProvider.future);
      for (final it in cache.entriesForImage(hash)) {
        final enc = await cache.get(hash, it.modelKey, it.ie);
        if (enc == null) continue;
        mergeEncodingIntoRaw(raw,
            modelKey: it.modelKey, infoExtracted: it.ie, encoding: enc);
      }
    }
    return raw;
  }

  // ---- 编辑 ----

  /// 改名 / 默认参数:同时回写文件(name / importInfo)与索引。
  Future<void> updateMeta(
    String id, {
    String? name,
    double? defaultStrength,
    double? defaultInfoExtracted,
  }) async {
    await future;
    final e = _byId(id);
    if (e == null) return;
    try {
      final raw =
          jsonDecode(await fileOf(e).readAsString()) as Map<String, dynamic>;
      if (name != null) raw['name'] = name;
      if (defaultStrength != null || defaultInfoExtracted != null) {
        final info = raw['importInfo'] is Map
            ? (raw['importInfo'] as Map).cast<String, dynamic>()
            : <String, dynamic>{};
        info['model'] ??= e.supportedModels.isNotEmpty
            ? (kEncodingKeyToModel[e.supportedModels.first] ??
                e.supportedModels.first)
            : 'nai-diffusion-4-5-full';
        if (defaultStrength != null) info['strength'] = defaultStrength;
        if (defaultInfoExtracted != null) {
          info['information_extracted'] = defaultInfoExtracted;
        }
        info['strength'] ??= e.defaultStrength ?? 0.6;
        info['information_extracted'] ??= e.defaultInfoExtracted ?? 1.0;
        raw['importInfo'] = info;
      }
      final text = jsonEncode(raw);
      await fileOf(e).writeAsString(text);
      await _upsert(e.copyWith(
        name: name,
        defaultStrength: defaultStrength,
        defaultInfoExtracted: defaultInfoExtracted,
        sizeBytes: text.length,
      ));
    } catch (err) {
      debugPrint('[vibe-lib] 更新失败: $err');
    }
  }

  /// 设置某条标签(整表覆盖):回写文件 tags + 索引。
  Future<void> setTags(String id, List<String> tags) async {
    await future;
    final e = _byId(id);
    if (e == null) return;
    try {
      final raw =
          jsonDecode(await fileOf(e).readAsString()) as Map<String, dynamic>;
      raw['tags'] = tags;
      await fileOf(e).writeAsString(jsonEncode(raw));
    } catch (err) {
      debugPrint('[vibe-lib] 写标签失败: $err');
    }
    await _upsert(e.copyWith(tags: tags));
  }

  /// 批量给多条**追加**标签(已有则跳过)。
  Future<void> addTagToAll(Iterable<String> ids, String tag) async {
    for (final id in ids) {
      final e = _byId(id);
      if (e == null || e.tags.contains(tag)) continue;
      await setTags(id, [...e.tags, tag]);
    }
  }

  /// 全局重命名标签(所有含 [old] 的条目改成 [neu],neu 已存在则合并去重)。
  Future<void> renameTag(String old, String neu) async {
    await future;
    if (old == neu || neu.isEmpty) return;
    for (final e in [..._entries]) {
      if (!e.tags.contains(old)) continue;
      final next = <String>[];
      for (final t in e.tags) {
        final r = t == old ? neu : t;
        if (!next.contains(r)) next.add(r);
      }
      await setTags(e.id, next);
    }
  }

  /// 全局删除标签(从所有条目移除)。
  Future<void> removeTag(String tag) async {
    await future;
    for (final e in [..._entries]) {
      if (!e.tags.contains(tag)) continue;
      await setTags(e.id, [for (final t in e.tags) if (t != tag) t]);
    }
  }

  Future<void> delete(String id) async {
    await future;
    final e = _byId(id);
    if (e == null) return;
    try {
      await fileOf(e).delete();
    } catch (_) {}
    try {
      await thumbOf(e).delete();
    } catch (_) {}
    await _setEntries([..._entries]..removeWhere((x) => x.id == id));
  }

  /// 生成成功后回写「最近使用」。
  Future<void> markUsed(Set<String> ids) async {
    await future;
    if (ids.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var hit = false;
    final list = <VibeEntry>[];
    for (final e in _entries) {
      if (ids.contains(e.id)) {
        hit = true;
        list.add(e.copyWith(lastUsedAt: now));
      } else {
        list.add(e);
      }
    }
    if (hit) await _setEntries(list);
  }

  // ---- 取用 ----

  /// 读原图字节(详情大图/添加到生成用);纯编码 vibe 返回 null。
  Future<Uint8List?> loadImageBytes(VibeEntry e) async {
    if (!e.hasImage) return null;
    try {
      final raw =
          jsonDecode(await fileOf(e).readAsString()) as Map<String, dynamic>;
      final img = raw['image'];
      if (img is! String || img.isEmpty) return null;
      return base64Decode(img);
    } catch (_) {
      return null;
    }
  }

  /// 取「可生成」数据:有图 → 原图字节 + 哈希(编码走统一编码服务);
  /// 纯编码 → 每模型键选一条编码(优先贴近默认 IE)+ 固定 IE。
  Future<VibeForGenerate?> loadForGenerate(VibeEntry e) async {
    try {
      final raw =
          jsonDecode(await fileOf(e).readAsString()) as Map<String, dynamic>;
      final p = ParsedVibe(raw);
      final img = p.imageBase64;
      if (img != null) {
        final bytes = base64Decode(img);
        final hash =
            e.imageHash ?? await compute(sha256HexOfBytes, bytes);
        return (
          image: bytes,
          imageHash: hash,
          encodedByModel: null,
          fixedInfoExtracted: e.defaultInfoExtracted ?? 1.0,
        );
      }
      final prefer = e.defaultInfoExtracted ?? p.defaultInfoExtracted ?? 1.0;
      final byModel = <String, String>{};
      double? pickedIe;
      for (final it in p.encodingItems) {
        final cur = byModel[it.modelKey];
        if (cur == null) {
          byModel[it.modelKey] = it.encoding;
          pickedIe ??= it.infoExtracted;
        } else if (it.infoExtracted != null &&
            (pickedIe == null ||
                (it.infoExtracted! - prefer).abs() < (pickedIe - prefer).abs())) {
          byModel[it.modelKey] = it.encoding;
          pickedIe = it.infoExtracted;
        }
      }
      if (byModel.isEmpty) return null;
      return (
        image: null,
        imageHash: null,
        encodedByModel: byModel,
        fixedInfoExtracted: pickedIe ?? prefer,
      );
    } catch (_) {
      return null;
    }
  }

  /// 详情页编码清单:文件自带 + 缓存新增,按 (modelKey, IE) 去重。
  Future<List<({String modelKey, double? ie})>> encodingList(VibeEntry e) async {
    final seen = <String>{};
    final out = <({String modelKey, double? ie})>[];
    void add(String modelKey, double? ie) {
      final k = '$modelKey|${ie == null ? '?' : jsNum(ie)}';
      if (seen.add(k)) out.add((modelKey: modelKey, ie: ie));
    }

    try {
      final raw =
          jsonDecode(await fileOf(e).readAsString()) as Map<String, dynamic>;
      for (final it in ParsedVibe(raw).encodingItems) {
        add(it.modelKey, it.infoExtracted);
      }
    } catch (_) {}
    final hash = e.imageHash;
    if (hash != null) {
      final cache = await ref.read(vibeCacheProvider.future);
      for (final it in cache.entriesForImage(hash)) {
        add(it.modelKey, it.ie);
      }
    }
    out.sort((a, b) {
      final c = a.modelKey.compareTo(b.modelKey);
      if (c != 0) return c;
      return (a.ie ?? 2).compareTo(b.ie ?? 2);
    });
    return out;
  }
}
