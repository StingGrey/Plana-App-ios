import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/util/image_pick.dart';
import '../gallery/gallery_state.dart';
import '../gallery/models.dart';
import '../generate/models.dart' show GenerateState;
import 'local_gallery_store.dart';

const Object _unset = Object();

String _historySignatureOf(Iterable<ResultImage> results) => [
  for (final result in results)
    [
      result.id,
      result.width,
      result.height,
      result.seed,
      result.createdAt,
      result.badge.name,
      result.batchIndex,
      result.hasInput,
    ].join(':'),
].join('|');

class LocalGalleryState {
  const LocalGalleryState({
    this.items = const [],
    this.categories = const [],
    this.collections = const [],
    this.query = '',
    this.category,
    this.favoritesOnly = false,
    this.collectionId,
    this.dateDays = 0,
    this.scanning = false,
    this.scanDone = 0,
    this.scanTotal = 0,
    this.error,
  });

  final List<LocalGalleryRecord> items;
  final List<String> categories;
  final List<LocalGalleryCollection> collections;
  final String query;
  final String? category;
  final bool favoritesOnly;
  final String? collectionId;

  /// 0 = all dates, otherwise a rolling number of days.
  final int dateDays;
  final bool scanning;
  final int scanDone;
  final int scanTotal;
  final String? error;

  bool get hasFilters =>
      query.trim().isNotEmpty ||
      category != null ||
      favoritesOnly ||
      collectionId != null ||
      dateDays > 0;

  List<LocalGalleryRecord> get filteredItems {
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'[\s,，]+'))
        .where((value) => value.isNotEmpty)
        .toList();
    return [
      for (final item in items)
        if ((category == null || item.category == category) &&
            (!favoritesOnly || item.favorite) &&
            (collectionId == null ||
                item.collectionIds.contains(collectionId)) &&
            _passesDate(item) &&
            terms.every(item.searchableText.contains))
          item,
    ];
  }

  bool _passesDate(LocalGalleryRecord item) {
    if (dateDays <= 0) return true;
    final now = DateTime.now();
    final cutoff = dateDays == 1
        ? DateTime(now.year, now.month, now.day)
        : now.subtract(Duration(days: dateDays));
    return item.createdAt >= cutoff.millisecondsSinceEpoch;
  }

  LocalGalleryState copyWith({
    List<LocalGalleryRecord>? items,
    List<String>? categories,
    List<LocalGalleryCollection>? collections,
    String? query,
    Object? category = _unset,
    bool? favoritesOnly,
    Object? collectionId = _unset,
    int? dateDays,
    bool? scanning,
    int? scanDone,
    int? scanTotal,
    Object? error = _unset,
  }) => LocalGalleryState(
    items: items ?? this.items,
    categories: categories ?? this.categories,
    collections: collections ?? this.collections,
    query: query ?? this.query,
    category: category == _unset ? this.category : category as String?,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    collectionId: collectionId == _unset
        ? this.collectionId
        : collectionId as String?,
    dateDays: dateDays ?? this.dateDays,
    scanning: scanning ?? this.scanning,
    scanDone: scanDone ?? this.scanDone,
    scanTotal: scanTotal ?? this.scanTotal,
    error: error == _unset ? this.error : error as String?,
  );
}

final localGalleryProvider =
    NotifierProvider<LocalGalleryNotifier, LocalGalleryState>(
      LocalGalleryNotifier.new,
    );

final localGalleryImageProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>(
      (ref, id) => ref.watch(appStoresProvider).localGallery.readImage(id),
    );

final localGalleryThumbProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>(
      (ref, id) => ref.watch(appStoresProvider).localGallery.readThumb(id),
    );

class LocalGalleryNotifier extends Notifier<LocalGalleryState> {
  LocalGalleryStore get _store => ref.read(appStoresProvider).localGallery;
  int _historySyncToken = 0;
  String? _historySignature;

  @override
  LocalGalleryState build() {
    ref.listen<GalleryState>(galleryProvider, (_, next) {
      final signature = _historySignatureOf(next.results);
      if (signature == _historySignature) return;
      unawaited(_syncHistory(next.results));
    });
    // AppStores loads the generated gallery before this provider is mounted.
    // Hydrate its references after the first frame so the local page immediately
    // includes history without making startup depend on snapshot decoding.
    Future.microtask(() {
      if (ref.mounted) unawaited(_primeHistory());
    });
    return LocalGalleryState(
      items: _store.initialItems,
      categories: _store.initialCategories,
      collections: _store.initialCollections,
    );
  }

  void setQuery(String value) => state = state.copyWith(query: value);

  void setCategory(String? value) => state = state.copyWith(category: value);

  void toggleFavoritesOnly() =>
      state = state.copyWith(favoritesOnly: !state.favoritesOnly);

  void setCollection(String? value) =>
      state = state.copyWith(collectionId: value);

  void setDateDays(int value) =>
      state = state.copyWith(dateDays: value < 0 ? 0 : value);

  void clearFilters() => state = state.copyWith(
    query: '',
    category: null,
    collectionId: null,
    dateDays: 0,
    favoritesOnly: false,
  );

  void refreshFromStore() {
    _syncFromStore();
    unawaited(_syncHistory(ref.read(galleryProvider).results));
  }

  Future<int> importPicked(Iterable<PickedImage> picked) async {
    var imported = 0;
    for (final file in picked) {
      try {
        final before = _store.initialItems.length;
        await _store.importBytes(file.bytes, file.name);
        if (_store.initialItems.length > before) imported++;
      } catch (_) {}
    }
    _syncFromStore();
    return imported;
  }

  Future<int> importPaths(Iterable<String> paths) async {
    var imported = 0;
    for (final path in paths) {
      final before = _store.initialItems.length;
      final result = await _store.importFile(File(path));
      if (result != null && _store.initialItems.length > before) imported++;
    }
    _syncFromStore();
    return imported;
  }

  Future<void> scanDirectory(String path) async {
    state = state.copyWith(
      scanning: true,
      scanDone: 0,
      scanTotal: 0,
      error: null,
    );
    try {
      await _store.scanDirectory(
        path,
        onProgress: (done, total) {
          state = state.copyWith(
            scanning: true,
            scanDone: done,
            scanTotal: total,
          );
        },
      );
      _syncFromStore();
      state = state.copyWith(scanning: false);
    } catch (e) {
      state = state.copyWith(scanning: false, error: _scanError(e));
    }
  }

  void toggleFavorite(String id) {
    final item = _item(id);
    if (item == null) return;
    _replace(item.copyWith(favorite: !item.favorite));
  }

  void setCategoryFor(Iterable<String> ids, String category) {
    final selected = ids.toSet();
    if (selected.isEmpty || category.trim().isEmpty) return;
    if (!_store.initialCategories.contains(category.trim())) {
      _store.setCategories([..._store.initialCategories, category.trim()]);
    }
    category = category.trim();
    for (final item in state.items) {
      if (selected.contains(item.id)) {
        _store.replaceItem(item.copyWith(category: category));
      }
    }
    _syncFromStore();
  }

  void setFavoriteFor(Iterable<String> ids, bool value) {
    final selected = ids.toSet();
    for (final item in state.items) {
      if (selected.contains(item.id)) {
        _store.replaceItem(item.copyWith(favorite: value));
      }
    }
    _syncFromStore();
  }

  void addToCollection(Iterable<String> ids, String collectionId) {
    final selected = ids.toSet();
    for (final item in state.items) {
      if (!selected.contains(item.id) ||
          item.collectionIds.contains(collectionId)) {
        continue;
      }
      _store.replaceItem(
        item.copyWith(collectionIds: [...item.collectionIds, collectionId]),
      );
    }
    _syncFromStore();
  }

  void removeFromCollection(Iterable<String> ids, String collectionId) {
    final selected = ids.toSet();
    for (final item in state.items) {
      if (!selected.contains(item.id)) continue;
      _store.replaceItem(
        item.copyWith(
          collectionIds: [
            for (final id in item.collectionIds)
              if (id != collectionId) id,
          ],
        ),
      );
    }
    _syncFromStore();
  }

  LocalGalleryCollection createCollection(String name) {
    final result = _store.createCollection(name);
    _syncFromStore();
    return result;
  }

  void deleteCollection(String id) {
    _store.deleteCollection(id);
    _syncFromStore();
    if (state.collectionId == id) setCollection(null);
  }

  Future<void> delete(Iterable<String> ids) async {
    final selected = ids.toSet();
    for (final id in selected) {
      final item = _item(id);
      if (item?.isHistoryReference == true) {
        // Removing a catalog reference must not destroy the generated result.
        _store.removeHistoryReference(id);
      } else {
        await _store.delete(id);
      }
    }
    _syncFromStore();
  }

  Future<void> clearAll() async {
    // clearAll is a local-catalog operation. History references are hidden and
    // their source images/snapshots remain available in the main history tab.
    await _store.clearAll();
    _syncFromStore();
  }

  Future<void> clearImported() async {
    await _store.clearImported();
    _syncFromStore();
  }

  void restoreHistory(String historyId) {
    _store.restoreHistory(historyId);
    _historySignature = null;
    unawaited(_syncHistory(ref.read(galleryProvider).results));
  }

  Future<void> _primeHistory() async {
    await _store.migrateGeneratedCopies();
    if (!ref.mounted) return;
    await _syncHistory(ref.read(galleryProvider).results);
  }

  /// Keep generated history in the local catalog as metadata-only references.
  /// The bytes and thumbnails are always read from GalleryStore, so saving a
  /// generated result to history never creates a second image file.
  Future<void> _syncHistory(Iterable<ResultImage> results) async {
    final list = results.toList();
    final signature = _historySignatureOf(list);
    if (signature == _historySignature) return;
    final token = ++_historySyncToken;
    final gallery = ref.read(appStoresProvider).gallery;

    LocalGalleryRecord? oldFor(String id) {
      for (final item in _store.initialItems) {
        if (item.isHistoryReference && item.historyId == id) return item;
      }
      return null;
    }

    // Publish lightweight references first. The local page can show the
    // history immediately; snapshot decoding and file sizing continue below.
    final quick = [
      for (final result in list)
        _historyRecord(
          result,
          result.input,
          oldFor(result.id),
          result.bytes?.length ?? oldFor(result.id)?.sizeBytes ?? 0,
        ),
    ];
    if (!ref.mounted || token != _historySyncToken) return;
    _store.syncHistory(quick);
    _syncFromStore();

    final references = <LocalGalleryRecord>[];
    for (final result in list) {
      if (!ref.mounted || token != _historySyncToken) return;
      // Read current metadata again: a user may have favorited or categorized
      // the quick reference while the snapshot was being decoded.
      final old = oldFor(result.id);
      GenerateState? input = result.input;
      if (input == null && result.hasInput) {
        input = await gallery.readInput(result.id);
        // The result and its snapshot are queued independently. If the first
        // read races the atomic snapshot write, wait for that owner's queue
        // once instead of permanently publishing a blank prompt index.
        if (input == null) {
          await gallery.idle;
          input = await gallery.readInput(result.id);
        }
      }
      if (!ref.mounted || token != _historySyncToken) return;
      final oldSize = old?.sizeBytes ?? 0;
      final size = oldSize > 0
          ? oldSize
          : (await gallery.imageLength(result.id) ?? result.bytes?.length ?? 0);
      if (!ref.mounted || token != _historySyncToken) return;
      references.add(_historyRecord(result, input, old, size));
    }
    if (!ref.mounted || token != _historySyncToken) return;
    _store.syncHistory(references);
    _historySignature = signature;
    _syncFromStore();
  }

  LocalGalleryRecord _historyRecord(
    ResultImage result,
    GenerateState? input,
    LocalGalleryRecord? old,
    int sizeBytes,
  ) {
    final seed = result.seed == 0 ? (old?.seed ?? '') : '${result.seed}';
    return LocalGalleryRecord(
      id: old?.id ?? 'history_${result.id}',
      name: old?.name ?? (seed.isEmpty ? '历史记录' : 'Seed $seed'),
      // This is only a display/export name. No file with this name is created
      // under local_gallery for a history reference.
      fileName: old?.fileName ?? '${result.id}.png',
      contentHash: old?.contentHash ?? '',
      createdAt: result.createdAt > 0
          ? result.createdAt
          : (old?.createdAt ?? 0),
      sizeBytes: sizeBytes,
      width: result.width,
      height: result.height,
      historyId: result.id,
      prompt: input?.prompt ?? old?.prompt ?? '',
      negativePrompt: input?.negativePrompt ?? old?.negativePrompt ?? '',
      model: input?.params.model ?? old?.model ?? '',
      sampler: input?.params.sampler ?? old?.sampler ?? '',
      seed: seed,
      steps: input?.params.activeSteps ?? old?.steps ?? 0,
      category: old?.category ?? '未分类',
      favorite: old?.favorite ?? false,
      collectionIds: old?.collectionIds ?? const [],
      characters: input == null
          ? (old?.characters ?? const [])
          : [
              for (final character in input.characters)
                LocalGalleryCharacter(
                  prompt: character.positive,
                  negativePrompt: character.negative,
                ),
            ],
    );
  }

  LocalGalleryRecord? _item(String id) {
    for (final item in state.items) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _replace(LocalGalleryRecord item) {
    _store.replaceItem(item);
    _syncFromStore();
  }

  void _syncFromStore() {
    state = state.copyWith(
      items: _store.initialItems,
      categories: _store.initialCategories,
      collections: _store.initialCollections,
      error: null,
    );
  }

  String _scanError(Object error) {
    if (error is FileSystemException) return error.message;
    return '扫描失败: $error';
  }
}
