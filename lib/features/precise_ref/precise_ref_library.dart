import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/store/atomic_file.dart';
import '../../core/util/image_ops.dart';

/// Reusable Precise Reference modes supported by the current NAI payload.
enum PreciseRefType { character, style, characterAndStyle }

extension PreciseRefTypeX on PreciseRefType {
  String get label => switch (this) {
    PreciseRefType.character => '角色',
    PreciseRefType.style => '风格',
    PreciseRefType.characterAndStyle => '角色&风格',
  };
}

class PreciseRefEntry {
  const PreciseRefEntry({
    required this.id,
    required this.name,
    required this.fileName,
    required this.createdAt,
    this.type = PreciseRefType.characterAndStyle,
    this.strength = 1,
    this.fidelity = 1,
    this.favorite = false,
    this.usedCount = 0,
    this.lastUsedAt = 0,
    this.sizeBytes = 0,
  });

  final String id;
  final String name;
  final String fileName;
  final int createdAt;
  final PreciseRefType type;
  final double strength;
  final double fidelity;
  final bool favorite;
  final int usedCount;
  final int lastUsedAt;
  final int sizeBytes;

  int get recency => lastUsedAt > 0 ? lastUsedAt : createdAt;

  PreciseRefEntry copyWith({
    String? name,
    PreciseRefType? type,
    double? strength,
    double? fidelity,
    bool? favorite,
    int? usedCount,
    int? lastUsedAt,
  }) => PreciseRefEntry(
    id: id,
    name: name ?? this.name,
    fileName: fileName,
    createdAt: createdAt,
    type: type ?? this.type,
    strength: strength ?? this.strength,
    fidelity: fidelity ?? this.fidelity,
    favorite: favorite ?? this.favorite,
    usedCount: usedCount ?? this.usedCount,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    sizeBytes: sizeBytes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'file': fileName,
    'createdAt': createdAt,
    'type': type.name,
    'strength': strength,
    'fidelity': fidelity,
    'favorite': favorite,
    'usedCount': usedCount,
    'lastUsedAt': lastUsedAt,
    'sizeBytes': sizeBytes,
  };

  static PreciseRefEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    final file = raw['file']?.toString() ?? '';
    if (id.isEmpty || file.isEmpty) return null;
    final type = PreciseRefType.values.firstWhere(
      (value) => value.name == raw['type'],
      orElse: () => PreciseRefType.characterAndStyle,
    );
    return PreciseRefEntry(
      id: id,
      name: raw['name']?.toString() ?? id,
      fileName: file,
      createdAt: _int(raw['createdAt']),
      type: type,
      strength: (((raw['strength'] as num?)?.toDouble() ?? 1).clamp(0, 1)).toDouble(),
      fidelity: (((raw['fidelity'] as num?)?.toDouble() ?? 1).clamp(0, 1)).toDouble(),
      favorite: raw['favorite'] == true,
      usedCount: _int(raw['usedCount']),
      lastUsedAt: _int(raw['lastUsedAt']),
      sizeBytes: _int(raw['sizeBytes']),
    );
  }
}

final preciseRefProvider =
    AsyncNotifierProvider<PreciseRefNotifier, List<PreciseRefEntry>>(
      PreciseRefNotifier.new,
    );

final preciseRefImageProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, id) async {
      final entries = await ref.watch(preciseRefProvider.future);
      final entry = entries.where((value) => value.id == id).firstOrNull;
      if (entry == null) return null;
      return ref.read(preciseRefProvider.notifier).loadBytes(entry);
    });

final preciseRefThumbProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, id) async {
      final entries = await ref.watch(preciseRefProvider.future);
      final entry = entries.where((value) => value.id == id).firstOrNull;
      if (entry == null) return null;
      return ref.read(preciseRefProvider.notifier).loadThumbnail(entry);
    });

class PreciseRefNotifier extends AsyncNotifier<List<PreciseRefEntry>> {
  Directory? _root;
  Future<List<PreciseRefEntry>>? _loadFuture;
  List<PreciseRefEntry> _loadedEntries = const [];

  Directory get _files => Directory('${_root!.path}/files');
  Directory get _thumbs => Directory('${_root!.path}/thumbs');
  File get _index => File('${_root!.path}/index.json');

  @override
  Future<List<PreciseRefEntry>> build() => _ensureLoaded();

  Future<List<PreciseRefEntry>> _ensureLoaded() async {
    final running = _loadFuture;
    if (running != null) return running;
    final future = () async {
      await _init();
      final entries = await _readIndex();
      _loadedEntries = entries;
      return entries;
    }();
    _loadFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_loadFuture, future)) _loadFuture = null;
    }
  }

  Future<void> _init() async {
    Directory support;
    try {
      support = await getApplicationSupportDirectory();
    } catch (_) {
      support = Directory.systemTemp;
    }
    _root = Directory('${support.path}/precise_reference_library');
    await _files.create(recursive: true);
    await _thumbs.create(recursive: true);
  }

  Future<List<PreciseRefEntry>> _readIndex() async {
    try {
      if (!await _index.exists()) return const [];
      final raw = jsonDecode(await _index.readAsString());
      if (raw is! Map || raw['entries'] is! List) return const [];
      final out = <PreciseRefEntry>[];
      for (final item in raw['entries'] as List) {
        final entry = PreciseRefEntry.fromJson(item);
        if (entry != null && await File('${_files.path}/${entry.fileName}').exists()) {
          out.add(entry);
        }
      }
      return List.unmodifiable(out);
    } catch (_) {
      return const [];
    }
  }

  List<PreciseRefEntry> get _entries => state.value ?? _loadedEntries;

  File fileOf(PreciseRefEntry entry) => File('${_files.path}/${entry.fileName}');
  File thumbOf(PreciseRefEntry entry) => File('${_thumbs.path}/${entry.id}.png');

  Future<PreciseRefEntry> importBytes(
    Uint8List bytes, {
    required String name,
    PreciseRefType type = PreciseRefType.characterAndStyle,
    double strength = 1,
    double fidelity = 1,
  }) async {
    await _ensureLoaded();
    final id = 'ref${DateTime.now().microsecondsSinceEpoch}';
    final fileName = '$id.img';
    await File('${_files.path}/$fileName').writeAsBytes(bytes, flush: true);
    try {
      await File('${_thumbs.path}/$id.png').writeAsBytes(
        await coverResizePng(bytes, 320, 320, keepAlpha: true),
        flush: true,
      );
    } catch (_) {}
    final entry = PreciseRefEntry(
      id: id,
      name: name.trim().isEmpty ? '精准参考' : name.trim(),
      fileName: fileName,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      type: type,
      strength: strength.clamp(0, 1).toDouble(),
      fidelity: fidelity.clamp(0, 1).toDouble(),
      sizeBytes: bytes.length,
    );
    await _setEntries([entry, ..._entries]);
    return entry;
  }

  Future<Uint8List?> loadBytes(PreciseRefEntry entry) async {
    try {
      return await fileOf(entry).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> loadThumbnail(PreciseRefEntry entry) async {
    try {
      final thumb = thumbOf(entry);
      if (await thumb.exists()) return await thumb.readAsBytes();
      final bytes = await loadBytes(entry);
      if (bytes == null) return null;
      final generated = await coverResizePng(
        bytes,
        320,
        320,
        keepAlpha: true,
      );
      try {
        await thumb.writeAsBytes(generated, flush: true);
      } catch (_) {}
      return generated;
    } catch (_) {
      return null;
    }
  }

  Future<void> toggleFavorite(String id) async {
    await _ensureLoaded();
    final entry = _find(id);
    if (entry == null) return;
    await _replace(entry.copyWith(favorite: !entry.favorite));
  }

  Future<void> updateEntry(
    String id, {
    String? name,
    PreciseRefType? type,
    double? strength,
    double? fidelity,
  }) async {
    await _ensureLoaded();
    final entry = _find(id);
    if (entry == null) return;
    await _replace(
      entry.copyWith(
        name: name,
        type: type,
        strength: strength,
        fidelity: fidelity,
      ),
    );
  }

  Future<void> recordUse(String id) async {
    await _ensureLoaded();
    final entry = _find(id);
    if (entry == null) return;
    await _replace(
      entry.copyWith(
        usedCount: entry.usedCount + 1,
        lastUsedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> delete(String id) async {
    await _ensureLoaded();
    final entry = _find(id);
    if (entry == null) return;
    try {
      await fileOf(entry).delete();
    } catch (_) {}
    try {
      await thumbOf(entry).delete();
    } catch (_) {}
    await _setEntries([for (final item in _entries) if (item.id != id) item]);
  }

  Future<void> clearAll() async {
    await _ensureLoaded();
    for (final entry in [..._entries]) {
      try {
        await fileOf(entry).delete();
      } catch (_) {}
      try {
        await thumbOf(entry).delete();
      } catch (_) {}
    }
    await _setEntries(const []);
  }

  Future<void> _replace(PreciseRefEntry entry) async {
    await _setEntries([for (final item in _entries) item.id == entry.id ? entry : item]);
  }

  PreciseRefEntry? _find(String id) {
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  Future<void> _setEntries(List<PreciseRefEntry> entries) async {
    final next = List<PreciseRefEntry>.unmodifiable(entries);
    _loadedEntries = next;
    state = AsyncData(next);
    try {
      await writeStringAtomic(
        _index,
        jsonEncode({'version': 1, 'entries': [for (final entry in next) entry.toJson()]}),
      );
    } catch (_) {}
  }
}

String _string(Object? value, [String fallback = '']) => value?.toString() ?? fallback;
int _int(Object? value) => value is num ? value.toInt() : int.tryParse(_string(value)) ?? 0;
