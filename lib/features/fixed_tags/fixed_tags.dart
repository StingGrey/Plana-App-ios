import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';

/// A reusable prompt fragment.
enum FixedTagSide { positive, negative }
enum FixedTagPosition { prefix, suffix }

class FixedTagEntry {
  const FixedTagEntry({
    required this.id,
    required this.name,
    required this.content,
    this.weight = 1.0,
    this.side = FixedTagSide.positive,
    this.position = FixedTagPosition.prefix,
    this.enabled = true,
    this.createdAt = 0,
  });

  final String id;
  final String name;
  final String content;
  final double weight;
  final FixedTagSide side;
  final FixedTagPosition position;
  final bool enabled;
  final int createdAt;

  String get weightedContent {
    if (content.isEmpty || (weight - 1).abs() < .001) return content;
    final layers = (log(weight.clamp(.5, 2.0)) / log(1.05)).round();
    if (layers > 0) return '${'{' * layers}$content${'}' * layers}';
    if (layers < 0) return '${'[' * -layers}$content${']' * -layers}';
    return content;
  }

  FixedTagEntry copyWith({
    String? name,
    String? content,
    double? weight,
    FixedTagSide? side,
    FixedTagPosition? position,
    bool? enabled,
  }) => FixedTagEntry(
    id: id,
    name: name ?? this.name,
    content: content ?? this.content,
    weight: weight ?? this.weight,
    side: side ?? this.side,
    position: position ?? this.position,
    enabled: enabled ?? this.enabled,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'content': content,
    'weight': weight,
    'side': side.name,
    'position': position.name,
    'enabled': enabled,
    'createdAt': createdAt,
  };

  static FixedTagEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    final content = raw['content']?.toString() ?? '';
    if (id.isEmpty || content.trim().isEmpty) return null;
    final side = FixedTagSide.values.firstWhere(
      (value) => value.name == raw['side'],
      orElse: () => FixedTagSide.positive,
    );
    final position = FixedTagPosition.values.firstWhere(
      (value) => value.name == raw['position'],
      orElse: () => FixedTagPosition.prefix,
    );
    return FixedTagEntry(
      id: id,
      name: raw['name']?.toString() ?? '',
      content: content,
      weight: (((raw['weight'] as num?)?.toDouble() ?? 1).clamp(.5, 2.0)).toDouble(),
      side: side,
      position: position,
      enabled: raw['enabled'] != false,
      createdAt: (raw['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class FixedTagsState {
  const FixedTagsState({this.entries = const []});

  final List<FixedTagEntry> entries;

  List<FixedTagEntry> get positive => entries
      .where((entry) => entry.side == FixedTagSide.positive)
      .toList(growable: false);
  List<FixedTagEntry> get negative => entries
      .where((entry) => entry.side == FixedTagSide.negative)
      .toList(growable: false);

  String apply(String prompt, FixedTagSide side) {
    final active = entries.where(
      (entry) => entry.enabled && entry.side == side && entry.content.trim().isNotEmpty,
    );
    final prefix = [
      for (final entry in active)
        if (entry.position == FixedTagPosition.prefix) entry.weightedContent,
    ];
    final suffix = [
      for (final entry in active)
        if (entry.position == FixedTagPosition.suffix) entry.weightedContent,
    ];
    return [...prefix, prompt.trim(), ...suffix]
        .where((part) => part.isNotEmpty)
        .join(', ');
  }
}

final fixedTagsProvider = NotifierProvider<FixedTagsNotifier, FixedTagsState>(
  FixedTagsNotifier.new,
);

class FixedTagsNotifier extends Notifier<FixedTagsState> {
  static const _key = 'fixed_tags_v1';

  @override
  FixedTagsState build() {
    final raw = ref.read(prefsStoreProvider).get(_key);
    final entries = <FixedTagEntry>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final value in decoded) {
            final entry = FixedTagEntry.fromJson(value);
            if (entry != null) entries.add(entry);
          }
        }
      } catch (_) {}
    }
    return FixedTagsState(entries: List.unmodifiable(entries));
  }

  String add({
    required String name,
    required String content,
    double weight = 1,
    FixedTagSide side = FixedTagSide.positive,
    FixedTagPosition position = FixedTagPosition.prefix,
  }) {
    final id = 'fixed${DateTime.now().microsecondsSinceEpoch}';
    final entry = FixedTagEntry(
      id: id,
      name: name.trim(),
      content: content.trim(),
      weight: weight.clamp(.5, 2.0).toDouble(),
      side: side,
      position: position,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (entry.content.isEmpty) return '';
    _set([...state.entries, entry]);
    return id;
  }

  void upsert(FixedTagEntry entry) {
    final entries = [...state.entries];
    final index = entries.indexWhere((value) => value.id == entry.id);
    if (index < 0) {
      entries.add(entry);
    } else {
      entries[index] = entry;
    }
    _set(entries);
  }

  void toggle(String id) {
    final entry = _find(id);
    if (entry == null) return;
    upsert(entry.copyWith(enabled: !entry.enabled));
  }

  void remove(String id) => _set([
    for (final entry in state.entries)
      if (entry.id != id) entry,
  ]);

  void reorder(FixedTagSide side, int oldIndex, int newIndex) {
    final selected = state.entries
        .where((entry) => entry.side == side)
        .toList(growable: true);
    if (oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= selected.length ||
        newIndex >= selected.length) {
      return;
    }
    selected.insert(newIndex, selected.removeAt(oldIndex));
    var cursor = 0;
    final all = [
      for (final entry in state.entries)
        entry.side == side ? selected[cursor++] : entry,
    ];
    _set(all);
  }

  void clear() => _set(const []);

  FixedTagEntry? _find(String id) {
    for (final entry in state.entries) {
      if (entry.id == id) {
        return entry;
      }
    }
    return null;
  }

  void _set(List<FixedTagEntry> entries) {
    state = FixedTagsState(entries: List.unmodifiable(entries));
    unawaited(
      ref.read(prefsStoreProvider).write(
        key: _key,
        value: jsonEncode([for (final entry in entries) entry.toJson()]),
      ),
    );
  }
}
