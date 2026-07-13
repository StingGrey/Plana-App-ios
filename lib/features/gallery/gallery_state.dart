import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../generate/models.dart' show GenerateState;
import 'models.dart';

final galleryProvider = NotifierProvider<GalleryNotifier, GalleryState>(
  GalleryNotifier.new,
);

/// 图库大图是否处于缩放/双指交互态;shell 据此锁 PageView 横滑,
/// 避免缩放拖动被翻页手势抢走。
final galleryZoomedProvider = NotifierProvider<GalleryZoomedNotifier, bool>(
  GalleryZoomedNotifier.new,
);

class GalleryZoomedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool v) {
    if (state != v) state = v;
  }
}

class GalleryState {
  const GalleryState({required this.results, required this.selectedId});

  final List<ResultImage> results;
  final String? selectedId;

  bool get isEmpty => results.isEmpty;

  /// 当前选中项;selectedId 失效时回退到最新一张。
  ResultImage? get selected {
    for (final r in results) {
      if (r.id == selectedId) return r;
    }
    return results.isEmpty ? null : results.first;
  }

  GalleryState copyWith({List<ResultImage>? results, String? selectedId}) =>
      GalleryState(
        results: results ?? this.results,
        selectedId: selectedId ?? this.selectedId,
      );
}

class GalleryNotifier extends Notifier<GalleryState> {
  int _seq = 0;

  @override
  GalleryState build() => const GalleryState(results: [], selectedId: null); // 空图库,由生成链路 push 真实结果

  void select(String id) {
    if (id == state.selectedId) return;
    state = state.copyWith(selectedId: id);
  }

  /// 生成链路产出真实结果:前插并选中。
  ResultImage addResult({
    required Uint8List bytes,
    required int width,
    required int height,
    required int seed,
    ResultBadge badge = ResultBadge.none,
    GenerateState? input,
  }) {
    final r = ResultImage(
      id: 'gen${_seq++}',
      width: width,
      height: height,
      seed: seed,
      badge: badge,
      bytes: bytes,
      input: input,
    );
    state = state.copyWith(results: [r, ...state.results], selectedId: r.id);
    return r;
  }
}
