import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/store/storage_settings.dart';
import '../generate/models.dart' show GenerateState;
import 'gallery_search.dart';
import 'models.dart';

final galleryProvider = NotifierProvider<GalleryNotifier, GalleryState>(
  GalleryNotifier.new,
);

/// 结果原图懒读(重启水合/RAM 减负后 bytes 不在内存时用)。
/// autoDispose:画布/操作层不看了就释放,不在内存里囤整库。
final galleryImageProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>(
      (ref, id) => ref.watch(appStoresProvider).gallery.readImage(id),
    );

/// 结果缩略图懒读(胶片条/网格用,缺缩略图时店内退回原图)。
final galleryThumbProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>(
      (ref, id) => ref.watch(appStoresProvider).gallery.readThumb(id),
    );

/// 图库大图是否处于缩放/双指交互态;shell 据此锁 PageView 横滑,
/// 避免缩放拖动被翻页手势抢走。
final galleryZoomedProvider = NotifierProvider<GalleryZoomedNotifier, bool>(
  GalleryZoomedNotifier.new,
);

/// 生成中画布视角:true=看生成预览(默认),false=生成中切看历史图。
/// 每次生成发起时复位为 true(对齐 web viewingHistory 语义,取反)。
final galleryViewGenProvider = NotifierProvider<GalleryViewGenNotifier, bool>(
  GalleryViewGenNotifier.new,
);

class GalleryViewGenNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool v) {
    if (state != v) state = v;
  }
}

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

  /// 最近这么多张保留内存字节;更旧的卸掉(盘上有,再看懒读),
  /// 挂机循环几百张不再无限吃 RAM。
  static const _keepBytesFor = 30;

  @override
  GalleryState build() {
    // 启动水合:索引给顺序/尺寸/选中,像素与快照按需懒读
    final store = ref.watch(appStoresProvider).gallery;
    _seq = store.seq;
    // 上限设置就绪/变更时裁剪(冷启动水合的超长历史也在这里收口)
    ref.listen(storageSettingsProvider, (_, next) {
      if (next.hasValue) enforceCap();
    });
    return GalleryState(
      results: store.initialResults,
      selectedId: store.initialSelectedId,
    );
  }

  /// 图库上限裁剪:超出上限删最旧(列表尾部),文件一并删。
  void enforceCap() {
    final cap = ref.read(storageSettingsProvider).value?.galleryCap ?? 0;
    if (cap <= 0 || state.results.length <= cap) return;
    final keep = state.results.sublist(0, cap);
    final drop = state.results.sublist(cap);
    // 选中项被裁掉时回退到最新一张
    final sel = keep.any((r) => r.id == state.selectedId)
        ? state.selectedId
        : (keep.isEmpty ? null : keep.first.id);
    state = GalleryState(results: keep, selectedId: sel);
    final dropIds = [for (final r in drop) r.id];
    ref.read(appStoresProvider).gallery.deleteResultFiles(dropIds);
    ref.read(gallerySearchProvider.notifier).removeAll(dropIds);
    _persistIndex();
  }

  void _persistIndex() {
    ref
        .read(appStoresProvider)
        .gallery
        .scheduleIndex(
          results: state.results,
          selectedId: state.selectedId,
          seq: _seq,
        );
  }

  void select(String id) {
    if (id == state.selectedId) return;
    state = state.copyWith(selectedId: id);
    _persistIndex();
  }

  /// 生成链路产出真实结果:前插并选中,同时落盘(原图/缩略图/参数快照)。
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
      createdAt: DateTime.now().millisecondsSinceEpoch,
      bytes: bytes,
      input: input,
    );
    // 检索索引同帧写入(input 在内存,零 IO)
    if (input != null) {
      ref.read(gallerySearchProvider.notifier).put(r.id, input);
    }
    var list = [r, ...state.results];
    if (list.length > _keepBytesFor) {
      list = [
        for (var i = 0; i < list.length; i++)
          i < _keepBytesFor ? list[i] : list[i].stripped(),
      ];
    }
    state = state.copyWith(results: list, selectedId: r.id);
    final store = ref.read(appStoresProvider).gallery;
    store.persistResult(r);
    // 重绘产物继承源图蒙版:消费一次即清空,之后两张各自独立编辑保存。
    final from = store.pendingMaskInheritFrom;
    if (from != null) {
      store.pendingMaskInheritFrom = null;
      if (badge == ResultBadge.inpaint) store.copyMask(from, r.id);
    }
    _persistIndex();
    enforceCap();
    return r;
  }

  /// 批量删除(展开网格多选):状态移除 + 盘上文件一并删。
  /// 选中项被删时回退到剩余的最新一张。
  void deleteResults(List<String> ids) {
    if (ids.isEmpty) return;
    final drop = ids.toSet();
    final keep = [
      for (final r in state.results)
        if (!drop.contains(r.id)) r,
    ];
    if (keep.length == state.results.length) return;
    final sel = keep.any((r) => r.id == state.selectedId)
        ? state.selectedId
        : (keep.isEmpty ? null : keep.first.id);
    state = GalleryState(results: keep, selectedId: sel);
    ref.read(appStoresProvider).gallery.deleteResultFiles(ids);
    ref.read(gallerySearchProvider.notifier).removeAll(ids);
    _persistIndex();
  }

  /// 清空图库(存储管理):内存态与盘上文件一并清,发号器保留不复用。
  void clearAll() {
    state = const GalleryState(results: [], selectedId: null);
    ref.read(appStoresProvider).gallery.clearAllFiles(seq: _seq);
    ref.read(gallerySearchProvider.notifier).clear();
  }
}
