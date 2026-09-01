import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/store/atomic_file.dart';
import '../../core/util/image_ops.dart';
import '../gallery/gallery_store.dart';
import '../gallery/models.dart';
import '../import/image_metadata.dart';

/// A catalog entry for an imported image or a generated-history reference.
///
/// External files are copied into app storage so an iOS document-provider URL
/// cannot expire underneath the UI. Generated results instead keep a
/// [historyId] and read their pixels from [GalleryStore], avoiding a duplicate.
class LocalGalleryRecord {
  const LocalGalleryRecord({
    required this.id,
    required this.name,
    required this.fileName,
    required this.contentHash,
    required this.createdAt,
    required this.sizeBytes,
    required this.width,
    required this.height,
    this.sourcePath = '',
    this.historyId,
    this.prompt = '',
    this.negativePrompt = '',
    this.model = '',
    this.sampler = '',
    this.seed = '',
    this.steps = 0,
    this.category = '未分类',
    this.favorite = false,
    this.collectionIds = const [],
    this.characters = const [],
  });

  final String id;
  final String name;
  final String fileName;
  final String contentHash;
  final int createdAt;
  final int sizeBytes;
  final int width;
  final int height;
  final String sourcePath;

  /// Generated-history records point at GalleryStore instead of owning another
  /// copy of the image. Imported files keep this null and live in the local
  /// gallery's own image directory.
  final String? historyId;
  final String prompt;
  final String negativePrompt;
  final String model;
  final String sampler;
  final String seed;
  final int steps;
  final String category;
  final bool favorite;
  final List<String> collectionIds;
  final List<LocalGalleryCharacter> characters;

  double get aspect => width > 0 && height > 0 ? width / height : 1;
  bool get isHistoryReference => historyId?.isNotEmpty == true;
  bool get hasMetadata =>
      prompt.isNotEmpty || model.isNotEmpty || seed.isNotEmpty;

  String get searchableText => [
    name,
    prompt,
    negativePrompt,
    model,
    sampler,
    seed,
    category,
    for (final c in characters) ...[c.prompt, c.negativePrompt],
  ].join(' ').toLowerCase();

  LocalGalleryRecord copyWith({
    String? name,
    String? category,
    bool? favorite,
    List<String>? collectionIds,
    String? prompt,
    String? negativePrompt,
    String? model,
    String? sampler,
    String? seed,
    int? steps,
    int? width,
    int? height,
    int? sizeBytes,
    List<LocalGalleryCharacter>? characters,
  }) => LocalGalleryRecord(
    id: id,
    name: name ?? this.name,
    fileName: fileName,
    contentHash: contentHash,
    createdAt: createdAt,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    width: width ?? this.width,
    height: height ?? this.height,
    sourcePath: sourcePath,
    historyId: historyId,
    prompt: prompt ?? this.prompt,
    negativePrompt: negativePrompt ?? this.negativePrompt,
    model: model ?? this.model,
    sampler: sampler ?? this.sampler,
    seed: seed ?? this.seed,
    steps: steps ?? this.steps,
    category: category ?? this.category,
    favorite: favorite ?? this.favorite,
    collectionIds: collectionIds ?? this.collectionIds,
    characters: characters ?? this.characters,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (!isHistoryReference) 'file': fileName,
    'hash': contentHash,
    'createdAt': createdAt,
    'size': sizeBytes,
    'width': width,
    'height': height,
    if (sourcePath.isNotEmpty) 'sourcePath': sourcePath,
    if (historyId != null && historyId!.isNotEmpty) 'historyId': historyId,
    'prompt': prompt,
    'negativePrompt': negativePrompt,
    'model': model,
    'sampler': sampler,
    'seed': seed,
    'steps': steps,
    'category': category,
    'favorite': favorite,
    'collections': collectionIds,
    if (characters.isNotEmpty)
      'characters': [for (final c in characters) c.toJson()],
  };

  static LocalGalleryRecord? fromJson(Map<dynamic, dynamic> j) {
    final id = j['id'];
    final file = j['file'];
    final historyId = _string(j['historyId']);
    // A history reference intentionally has no file in local_gallery/images.
    if (id is! String ||
        id.isEmpty ||
        ((file is! String || file.isEmpty) && historyId.isEmpty)) {
      return null;
    }
    final fileName = file is String && file.isNotEmpty
        ? file
        : '${historyId.isEmpty ? id : historyId}.png';
    final rawChars = j['characters'];
    final characters = <LocalGalleryCharacter>[];
    if (rawChars is List) {
      for (final raw in rawChars) {
        if (raw is! Map) continue;
        final value = LocalGalleryCharacter.fromJson(raw);
        if (value != null) characters.add(value);
      }
    }
    return LocalGalleryRecord(
      id: id,
      name: _string(j['name'], fileName),
      fileName: fileName,
      contentHash: _string(j['hash']),
      createdAt: _int(j['createdAt']),
      sizeBytes: _int(j['size']),
      width: _int(j['width']),
      height: _int(j['height']),
      sourcePath: _string(j['sourcePath']),
      historyId: historyId.isEmpty ? null : historyId,
      prompt: _string(j['prompt']),
      negativePrompt: _string(j['negativePrompt']),
      model: _string(j['model']),
      sampler: _string(j['sampler']),
      seed: _string(j['seed']),
      steps: _int(j['steps']),
      category: _string(j['category'], '未分类'),
      favorite: j['favorite'] == true,
      collectionIds: _strings(j['collections']),
      characters: characters,
    );
  }
}

class LocalGalleryCharacter {
  const LocalGalleryCharacter({this.prompt = '', this.negativePrompt = ''});

  final String prompt;
  final String negativePrompt;

  Map<String, dynamic> toJson() => {
    'prompt': prompt,
    'negativePrompt': negativePrompt,
  };

  static LocalGalleryCharacter? fromJson(Map<dynamic, dynamic> j) {
    if (j['prompt'] is! String && j['negativePrompt'] is! String) {
      return null;
    }
    return LocalGalleryCharacter(
      prompt: _string(j['prompt']),
      negativePrompt: _string(j['negativePrompt']),
    );
  }
}

class LocalGalleryCollection {
  const LocalGalleryCollection({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String name;
  final int createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt,
  };

  static LocalGalleryCollection? fromJson(Map<dynamic, dynamic> j) {
    final id = j['id'];
    final name = j['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    return LocalGalleryCollection(
      id: id,
      name: name,
      createdAt: _int(j['createdAt']),
    );
  }
}

/// Persistent catalog for local imports and generated-history references.
class LocalGalleryStore {
  LocalGalleryStore(Directory supportRoot, {this.historyStore})
    : _root = Directory('${supportRoot.path}/local_gallery');

  /// The generated gallery is the owner of history pixels. This optional
  /// dependency keeps the store usable in isolation (including old tests and
  /// migrations), while production reads history references from one source.
  final GalleryStore? historyStore;
  final Directory _root;
  Directory get _images => Directory('${_root.path}/images');
  Directory get _thumbs => Directory('${_root.path}/thumbs');
  File get _index => File('${_root.path}/index.json');

  List<LocalGalleryRecord> initialItems = const [];
  List<LocalGalleryCollection> initialCollections = const [];
  List<String> initialCategories = const ['未分类', '角色', '风景', '灵感'];

  /// History ids explicitly removed from the local catalog. Keeping this
  /// separate from GalleryStore makes "移出本地图库" non-destructive.
  Set<String> hiddenHistoryIds = <String>{};
  int seq = 0;

  Future<void> load() async {
    await _images.create(recursive: true);
    await _thumbs.create(recursive: true);
    try {
      if (!await _index.exists()) {
        await _rebuild();
        return;
      }
      final decoded = jsonDecode(await _index.readAsString());
      if (decoded is! Map) {
        await _rebuild();
        return;
      }
      seq = _int(decoded['seq']);
      final rawItems = decoded['items'];
      final items = <LocalGalleryRecord>[];
      if (rawItems is List) {
        for (final item in rawItems) {
          if (item is Map) {
            final value = LocalGalleryRecord.fromJson(item);
            if (value != null &&
                (value.isHistoryReference || await _fileFor(value).exists())) {
              items.add(value);
            }
          }
        }
      }
      final rawCollections = decoded['collections'];
      final collections = <LocalGalleryCollection>[];
      if (rawCollections is List) {
        for (final item in rawCollections) {
          if (item is Map) {
            final value = LocalGalleryCollection.fromJson(item);
            if (value != null) collections.add(value);
          }
        }
      }
      final rawCategories = decoded['categories'];
      final categories = rawCategories is List
          ? [
              for (final c in rawCategories)
                if (c is String && c.trim().isNotEmpty) c,
            ]
          : initialCategories;
      final rawHidden = decoded['hiddenHistoryIds'];
      hiddenHistoryIds = {
        for (final id in rawHidden is List ? rawHidden : const [])
          if (id is String && id.trim().isNotEmpty) id,
      };
      initialItems = List.unmodifiable(items);
      initialCollections = List.unmodifiable(collections);
      initialCategories = _mergeCategories(categories);
      seq = seq > _nextSeq(items) ? seq : _nextSeq(items);
      await _repairIndexIfNeeded(
        items.length != (rawItems is List ? rawItems.length : 0),
      );
    } catch (_) {
      await _rebuild();
    }
  }

  File _fileFor(LocalGalleryRecord item) =>
      File('${_images.path}/${item.fileName}');
  File thumbFor(LocalGalleryRecord item) =>
      File('${_thumbs.path}/${item.id}.png');

  Future<Uint8List?> readImage(String id) async {
    final item = _find(id);
    if (item == null) return null;
    if (item.isHistoryReference) {
      final source = historyStore;
      final historyId = item.historyId;
      return source == null || historyId == null
          ? null
          : source.readImage(historyId);
    }
    try {
      return await _fileFor(item).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> readThumb(String id) async {
    final item = _find(id);
    if (item == null) return null;
    if (item.isHistoryReference) {
      final source = historyStore;
      final historyId = item.historyId;
      return source == null || historyId == null
          ? null
          : source.readThumb(historyId);
    }
    try {
      final thumb = thumbFor(item);
      if (await thumb.exists()) return await thumb.readAsBytes();
    } catch (_) {}
    return readImage(id);
  }

  LocalGalleryRecord? _find(String id) {
    for (final item in initialItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// Imports a file and returns the existing record when its content is already
  /// present. Metadata extraction is best-effort so ordinary non-NAI images
  /// still become useful local-gallery records.
  Future<LocalGalleryRecord> importBytes(
    Uint8List bytes,
    String fileName, {
    String? sourcePath,
    int? createdAt,
    String? promptOverride,
    String? negativePromptOverride,
    String? modelOverride,
    String? samplerOverride,
    String? seedOverride,
    int? stepsOverride,
    List<LocalGalleryCharacter>? charactersOverride,
  }) async {
    if (bytes.isEmpty) throw const FormatException('图片为空');
    final hash = sha256.convert(bytes).toString();

    // Importing a file that is already in generated history should create a
    // catalog reference, not a third copy under local_gallery. This also
    // covers a user re-importing an image exported from the app.
    final history = await _historyForHash(hash);
    if (history != null) {
      for (final item in initialItems) {
        if (item.historyId == history.id) return item;
      }
      // An explicit re-import is also the opt-in path for a previously hidden
      // history entry.
      hiddenHistoryIds.remove(history.id);
      final legacy = initialItems
          .where((item) => !item.isHistoryReference && item.contentHash == hash)
          .firstOrNull;
      final reference = legacy == null
          ? LocalGalleryRecord(
              id: 'history_${history.id}',
              name: _displayName(fileName, history.id),
              fileName: '${history.id}.png',
              contentHash: hash,
              createdAt: history.createdAt,
              sizeBytes: bytes.length,
              width: history.width,
              height: history.height,
              historyId: history.id,
              prompt: promptOverride ?? '',
              negativePrompt: negativePromptOverride ?? '',
              model: modelOverride ?? '',
              sampler: samplerOverride ?? '',
              seed:
                  seedOverride ?? (history.seed == 0 ? '' : '${history.seed}'),
              steps: stepsOverride ?? 0,
              characters: charactersOverride ?? const [],
            )
          : _asHistoryReference(legacy, history);
      if (legacy != null) await _deleteLocalFiles(legacy);
      initialItems = List.unmodifiable([
        reference,
        for (final item in initialItems)
          if (item.id != legacy?.id) item,
      ]);
      _scheduleIndex();
      return reference;
    }

    for (final item in initialItems) {
      if (item.contentHash == hash && hash.isNotEmpty) {
        if (promptOverride != null ||
            negativePromptOverride != null ||
            modelOverride != null ||
            samplerOverride != null ||
            seedOverride != null ||
            stepsOverride != null ||
            charactersOverride != null) {
          final enriched = item.copyWith(
            prompt: promptOverride,
            negativePrompt: negativePromptOverride,
            model: modelOverride,
            sampler: samplerOverride,
            seed: seedOverride,
            steps: stepsOverride,
            characters: charactersOverride,
          );
          replaceItem(enriched);
          return enriched;
        }
        return item;
      }
    }

    ImageMetadata? meta;
    try {
      meta = await extractImageMetadata(bytes);
    } catch (_) {}
    var width = meta?.width ?? 0;
    var height = meta?.height ?? 0;
    if (width <= 0 || height <= 0) {
      try {
        final size = await decodeImageSize(bytes);
        width = size.$1;
        height = size.$2;
      } catch (_) {}
    }

    final id = 'local${seq++}';
    final ext = _safeExtension(fileName, bytes);
    final item = LocalGalleryRecord(
      id: id,
      name: _displayName(fileName, id),
      fileName: '$id.$ext',
      contentHash: hash,
      createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch,
      sizeBytes: bytes.length,
      width: width,
      height: height,
      sourcePath: sourcePath ?? '',
      prompt: promptOverride ?? meta?.prompt ?? '',
      negativePrompt: negativePromptOverride ?? meta?.negativePrompt ?? '',
      model: modelOverride ?? meta?.source ?? '',
      sampler: samplerOverride ?? meta?.sampler ?? '',
      seed: seedOverride ?? meta?.seed ?? '',
      steps: stepsOverride ?? int.tryParse(meta?.steps ?? '') ?? 0,
      characters:
          charactersOverride ??
          [
            if (meta != null)
              for (final c in meta.characters)
                LocalGalleryCharacter(
                  prompt: c.prompt,
                  negativePrompt: c.uc ?? '',
                ),
          ],
    );
    await writeBytesAtomic(_fileFor(item), bytes);
    try {
      await writeBytesAtomic(
        thumbFor(item),
        await coverResizePng(bytes, 320, 320, keepAlpha: true),
      );
    } catch (_) {}
    initialItems = List.unmodifiable([item, ...initialItems]);
    _scheduleIndex();
    return item;
  }

  Future<LocalGalleryRecord?> importFile(File file) async {
    try {
      final stat = await file.stat();
      return await importBytes(
        await file.readAsBytes(),
        file.uri.pathSegments.last,
        sourcePath: file.path,
        createdAt: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(String id) async {
    final item = _find(id);
    if (item == null) return;
    initialItems = List.unmodifiable([
      for (final x in initialItems)
        if (x.id != id) x,
    ]);
    if (!item.isHistoryReference) {
      try {
        await _fileFor(item).delete();
      } catch (_) {}
      try {
        await thumbFor(item).delete();
      } catch (_) {}
    }
    _scheduleIndex();
  }

  void replaceItem(LocalGalleryRecord item) {
    initialItems = List.unmodifiable([
      for (final x in initialItems) x.id == item.id ? item : x,
    ]);
    _scheduleIndex();
  }

  /// Replace the generated-history part of the catalog without touching
  /// imported files. The records contain only metadata and a [historyId]; no
  /// image or thumbnail is copied into local_gallery for those references.
  void syncHistory(Iterable<LocalGalleryRecord> references) {
    final liveHistoryIds = {
      for (final item in references)
        if (item.historyId != null) item.historyId!,
    };
    // IDs are never reused by GalleryStore, so an exclusion for a deleted
    // history result is no longer useful and should not leave a dead badge.
    hiddenHistoryIds.removeWhere((id) => !liveHistoryIds.contains(id));
    final visible = [
      for (final item in references)
        if (!hiddenHistoryIds.contains(item.historyId)) item,
    ];
    final imported = [
      for (final item in initialItems)
        if (!item.isHistoryReference) item,
    ];
    final merged = [...visible, ...imported]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    initialItems = List.unmodifiable(merged);
    _scheduleIndex();
  }

  /// Remove a history item from this catalog without deleting its source image
  /// or parameter snapshot. It can be restored by [restoreHistory].
  void removeHistoryReference(String localId) {
    final item = _find(localId);
    final historyId = item?.historyId;
    if (historyId == null || historyId.isEmpty) return;
    hiddenHistoryIds.add(historyId);
    initialItems = List.unmodifiable([
      for (final value in initialItems)
        if (value.id != localId) value,
    ]);
    _scheduleIndex();
  }

  void restoreHistory(String historyId) {
    if (historyId.trim().isEmpty || !hiddenHistoryIds.remove(historyId)) return;
    _scheduleIndex();
  }

  /// Convert copies made by older versions' "save to local gallery" action
  /// into references before the catalog is displayed. Matching is by content
  /// hash, so the migration also handles renamed legacy files. The generated
  /// GalleryStore remains the sole pixel owner after this finishes.
  Future<int> migrateGeneratedCopies() async {
    final source = historyStore;
    if (source == null ||
        initialItems.isEmpty ||
        source.initialResults.isEmpty ||
        !initialItems.any((item) => !item.isHistoryReference)) {
      return 0;
    }
    final byHash = <String, ResultImage>{};
    for (final result in source.initialResults) {
      final bytes = await source.readImage(result.id);
      if (bytes == null || bytes.isEmpty) continue;
      byHash[sha256.convert(bytes).toString()] = result;
    }
    if (byHash.isEmpty) return 0;

    final existingHistoryIds = {
      for (final item in initialItems)
        if (item.isHistoryReference && item.historyId != null) item.historyId!,
    };
    final seen = {...existingHistoryIds};
    final next = <LocalGalleryRecord>[];
    var migrated = 0;
    for (final item in initialItems) {
      if (item.isHistoryReference) {
        next.add(item);
        continue;
      }
      final result = byHash[item.contentHash];
      if (result == null) {
        next.add(item);
        continue;
      }
      // A reference already present wins; otherwise preserve the user's local
      // labels/favorites while changing only the ownership relation.
      if (seen.add(result.id)) {
        next.add(_asHistoryReference(item, result));
      }
      await _deleteLocalFiles(item);
      migrated++;
    }
    if (migrated == 0) return 0;
    next.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    initialItems = List.unmodifiable(next);
    _scheduleIndex();
    return migrated;
  }

  LocalGalleryRecord _asHistoryReference(
    LocalGalleryRecord item,
    ResultImage result,
  ) => LocalGalleryRecord(
    id: item.id,
    name: item.name,
    fileName: item.fileName,
    contentHash: item.contentHash,
    createdAt: result.createdAt > 0 ? result.createdAt : item.createdAt,
    sizeBytes: item.sizeBytes,
    width: result.width > 0 ? result.width : item.width,
    height: result.height > 0 ? result.height : item.height,
    sourcePath: item.sourcePath,
    historyId: result.id,
    prompt: item.prompt,
    negativePrompt: item.negativePrompt,
    model: item.model,
    sampler: item.sampler,
    seed: item.seed,
    steps: item.steps,
    category: item.category,
    favorite: item.favorite,
    collectionIds: item.collectionIds,
    characters: item.characters,
  );

  Future<void> _deleteLocalFiles(LocalGalleryRecord item) async {
    for (final file in [_fileFor(item), thumbFor(item)]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<ResultImage?> _historyForHash(String hash) async {
    final source = historyStore;
    if (source == null || hash.isEmpty) return null;
    for (final result in source.initialResults) {
      final bytes = await source.readImage(result.id);
      if (bytes != null && sha256.convert(bytes).toString() == hash) {
        return result;
      }
    }
    return null;
  }

  LocalGalleryCollection createCollection(String name) {
    final clean = name.trim();
    for (final existing in initialCollections) {
      if (existing.name == clean && clean.isNotEmpty) return existing;
    }
    final collection = LocalGalleryCollection(
      id: 'collection${DateTime.now().microsecondsSinceEpoch}',
      name: clean.isEmpty ? '未命名集合' : clean,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    initialCollections = List.unmodifiable([...initialCollections, collection]);
    _scheduleIndex();
    return collection;
  }

  void renameCollection(String id, String name) {
    final clean = name.trim();
    if (clean.isEmpty) return;
    initialCollections = List.unmodifiable([
      for (final collection in initialCollections)
        collection.id == id
            ? LocalGalleryCollection(
                id: collection.id,
                name: clean,
                createdAt: collection.createdAt,
              )
            : collection,
    ]);
    _scheduleIndex();
  }

  void deleteCollection(String id) {
    initialCollections = List.unmodifiable([
      for (final c in initialCollections)
        if (c.id != id) c,
    ]);
    initialItems = List.unmodifiable([
      for (final item in initialItems)
        item.copyWith(
          collectionIds: [
            for (final c in item.collectionIds)
              if (c != id) c,
          ],
        ),
    ]);
    _scheduleIndex();
  }

  void setCategories(List<String> categories) {
    initialCategories = _mergeCategories(categories);
    _scheduleIndex();
  }

  /// Delete only copied external files. History references remain in
  /// the catalog and their source files in GalleryStore are untouched.
  Future<void> clearImported() async {
    initialItems = List.unmodifiable([
      for (final item in initialItems)
        if (item.isHistoryReference) item,
    ]);
    _scheduleIndex();
    for (final dir in [_images, _thumbs]) {
      try {
        if (await dir.exists()) {
          await for (final entry in dir.list()) {
            try {
              await entry.delete(recursive: true);
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    flushIndex();
    await idle;
  }

  Future<void> clearAll() async {
    hiddenHistoryIds.addAll([
      for (final item in initialItems)
        if (item.isHistoryReference && item.historyId != null) item.historyId!,
    ]);
    initialItems = const [];
    initialCollections = const [];
    _scheduleIndex();
    for (final dir in [_images, _thumbs]) {
      try {
        if (await dir.exists()) {
          await for (final entry in dir.list()) {
            try {
              await entry.delete(recursive: true);
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    // Flush after deletion as well as scheduling above: the debounce timer may
    // not have fired while the file loop was running.
    flushIndex();
    await idle;
  }

  Future<void> scanDirectory(
    String path, {
    void Function(int done, int total)? onProgress,
  }) async {
    final dir = Directory(path);
    if (!await dir.exists()) throw const FileSystemException('文件夹不存在');
    final files = <File>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          _isImageName(entity.path) &&
          !_isThumbnailPath(entity.path)) {
        files.add(entity);
      }
    }
    var done = 0;
    for (final file in files) {
      await importFile(file);
      done++;
      onProgress?.call(done, files.length);
    }
  }

  // ---- index writing ----
  Future<void> _chain = Future.value();
  Timer? _indexTimer;
  bool _indexPending = false;

  void _scheduleIndex() {
    _indexPending = true;
    _indexTimer?.cancel();
    _indexTimer = Timer(const Duration(milliseconds: 350), flushIndex);
  }

  void flushIndex() {
    if (!_indexPending) return;
    _indexPending = false;
    _indexTimer?.cancel();
    final payload = jsonEncode({
      'version': 1,
      'seq': seq,
      'hiddenHistoryIds': hiddenHistoryIds.toList(),
      'categories': initialCategories,
      'collections': [for (final c in initialCollections) c.toJson()],
      'items': [for (final item in initialItems) item.toJson()],
    });
    _chain = _chain.then((_) async {
      try {
        await writeStringAtomic(_index, payload);
      } catch (_) {}
    });
  }

  Future<void> get idle => _chain;
  Future<void> flush() {
    if (_indexPending) flushIndex();
    return _chain;
  }

  Future<void> _repairIndexIfNeeded(bool changed) async {
    if (changed) {
      _scheduleIndex();
      flushIndex();
    }
  }

  Future<void> _rebuild() async {
    final records = <LocalGalleryRecord>[];
    try {
      await for (final entity in _images.list()) {
        if (entity is! File || !_isImageName(entity.path)) continue;
        final fileName = entity.uri.pathSegments.last;
        final id = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
        try {
          final stat = await entity.stat();
          final bytes = await entity.readAsBytes();
          final hash = sha256.convert(bytes).toString();
          ImageMetadata? metadata;
          try {
            metadata = await extractImageMetadata(bytes);
          } catch (_) {}
          var width = metadata?.width ?? 0;
          var height = metadata?.height ?? 0;
          if (width <= 0 || height <= 0) {
            try {
              final size = await decodeImageSize(bytes);
              width = size.$1;
              height = size.$2;
            } catch (_) {}
          }
          records.add(
            LocalGalleryRecord(
              id: id,
              name: id,
              fileName: fileName,
              contentHash: hash,
              createdAt: stat.modified.millisecondsSinceEpoch,
              sizeBytes: stat.size,
              width: width,
              height: height,
              prompt: metadata?.prompt ?? '',
              negativePrompt: metadata?.negativePrompt ?? '',
              model: metadata?.source ?? '',
              sampler: metadata?.sampler ?? '',
              seed: metadata?.seed ?? '',
              steps: int.tryParse(metadata?.steps ?? '') ?? 0,
              characters: [
                if (metadata != null)
                  for (final character in metadata.characters)
                    LocalGalleryCharacter(
                      prompt: character.prompt,
                      negativePrompt: character.uc ?? '',
                    ),
              ],
            ),
          );
        } catch (_) {}
      }
    } catch (_) {}
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    initialItems = List.unmodifiable(records);
    hiddenHistoryIds = <String>{};
    seq = _nextSeq(records);
    _scheduleIndex();
    flushIndex();
  }

  int _nextSeq(Iterable<LocalGalleryRecord> records) {
    var n = 0;
    for (final item in records) {
      final match = RegExp(r'^local(\d+)$').firstMatch(item.id);
      final value = int.tryParse(match?.group(1) ?? '');
      if (value != null && value + 1 > n) n = value + 1;
    }
    return n;
  }

  List<String> _mergeCategories(Iterable<String> values) {
    final out = <String>[];
    for (final value in [...initialCategories, ...values]) {
      final clean = value.trim();
      if (clean.isNotEmpty && !out.contains(clean)) out.add(clean);
    }
    return List.unmodifiable(out);
  }
}

bool _isImageName(String path) =>
    RegExp(r'\.(png|jpe?g|webp|gif|bmp)$', caseSensitive: false).hasMatch(path);

bool _isThumbnailPath(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  const names = {
    '.thumbs',
    'thumbs',
    '.thumb',
    'thumb',
    'thumbnails',
    '.thumbnails',
    'cache',
    '.cache',
  };
  return parts.any((part) => names.contains(part.toLowerCase())) ||
      (parts.isNotEmpty && parts.last.startsWith('.'));
}

String _safeExtension(String name, Uint8List bytes) {
  final match = RegExp(r'\.([A-Za-z0-9]+)$').firstMatch(name);
  final ext = match?.group(1)?.toLowerCase();
  if (ext == 'jpeg') return 'jpg';
  if (ext != null && const {'png', 'jpg', 'webp', 'gif', 'bmp'}.contains(ext)) {
    return ext;
  }
  if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
  return 'png';
}

String _displayName(String name, String fallback) {
  final base = name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
  return base.isEmpty ? fallback : base;
}

String _string(Object? value, [String fallback = '']) =>
    value?.toString() ?? fallback;

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

List<String> _strings(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String && item.isNotEmpty) item,
      ]
    : const [];
