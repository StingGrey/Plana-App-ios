import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../../../core/store/app_stores.dart';
import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../gallery_state.dart';
import '../models.dart';
import '../save_pipeline.dart';
import '../save_settings.dart';
import 'result_badge_chip.dart';
import 'result_thumb.dart';
import '../../../core/util/haptics.dart';

/// 「›」展开:全部作品网格弹层。点选一张即回填画布并关闭;
/// 长按缩略图或点「多选」进入多选,底部批量保存相册 / 批量删除。
/// [selectId] 传入时直接以多选态打开并预选该张(胶片条长按入口)。
Future<void> showGalleryGrid(BuildContext context, {String? selectId}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GalleryGridSheet(initialSelectId: selectId),
    );

class _GalleryGridSheet extends ConsumerStatefulWidget {
  const _GalleryGridSheet({this.initialSelectId});

  final String? initialSelectId;

  @override
  ConsumerState<_GalleryGridSheet> createState() => _GalleryGridSheetState();
}

class _GalleryGridSheetState extends ConsumerState<_GalleryGridSheet> {
  bool _selecting = false;
  final Set<String> _picked = {};
  bool _saving = false;
  int _saveDone = 0;
  int _saveTotal = 0;

  @override
  void initState() {
    super.initState();
    final pre = widget.initialSelectId;
    if (pre != null) {
      _selecting = true;
      _picked.add(pre);
    }
  }

  void _enterSelect([String? pick]) {
    setState(() {
      _selecting = true;
      if (pick != null) _picked.add(pick);
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _picked.clear();
    });
  }

  void _toggle(String id) {
    setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id));
  }

  void _toggleAll(List<ResultImage> results) {
    setState(() {
      if (_picked.length == results.length) {
        _picked.clear();
      } else {
        _picked
          ..clear()
          ..addAll([for (final r in results) r.id]);
      }
    });
  }

  /// 批量保存:按默认保存设置逐张处理后存相册;逐张计数,
  /// 中途关闭弹层即中止(已存的保留)。
  Future<void> _downloadPicked() async {
    final items = [
      for (final r in ref.read(galleryProvider).results)
        if (_picked.contains(r.id)) r,
    ];
    if (items.isEmpty) return;
    final ok = await Gal.hasAccess() || await Gal.requestAccess();
    if (!mounted) return;
    if (!ok) {
      hintSnack(context, '未获相册权限', icon: Icons.error_outline);
      return;
    }
    final settings = await ref.read(saveSettingsProvider.future);
    if (!mounted) return;
    final store = ref.read(appStoresProvider).gallery;
    setState(() {
      _saving = true;
      _saveDone = 0;
      _saveTotal = items.length;
    });
    var saved = 0, failed = 0;
    for (final r in items) {
      if (!mounted) return; // 弹层已关:中止剩余
      try {
        final bytes = r.bytes ?? await store.readImage(r.id);
        if (bytes == null) {
          failed++;
        } else {
          final out = await processForSave(bytes, settings);
          await Gal.putImageBytes(out, name: 'plana_${r.seed}');
          saved++;
        }
      } catch (_) {
        failed++;
      }
      if (mounted) setState(() => _saveDone = saved + failed);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    hintSnack(
      context,
      failed == 0 ? '已保存 $saved 张到相册' : '保存 $saved 张,失败 $failed 张',
      icon: failed == 0 ? Icons.check_circle_outline : Icons.error_outline,
    );
  }

  Future<void> _deletePicked() async {
    final ids = _picked.toList();
    if (ids.isEmpty) return;
    final scheme = context.scheme;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('删除 ${ids.length} 张作品?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    ref.read(galleryProvider.notifier).deleteResults(ids);
    _exitSelect();
    if (ref.read(galleryProvider).results.isEmpty) {
      Navigator.of(context).pop(); // 删空了,弹层没得看
    }
    hintSnack(context, '已删除 ${ids.length} 张', icon: Icons.delete_outline);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(galleryProvider);
    final results = state.results;
    // 弹层开着期间条目可能被裁剪/删除,勾选集随之收敛
    _picked.removeWhere((id) => !results.any((r) => r.id == id));
    final scheme = context.scheme;
    final h = MediaQuery.of(context).size.height * 0.82;
    final canAct = _picked.isNotEmpty && !_saving;

    return SizedBox(
      height: h,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
            child: SizedBox(
              height: 36,
              child: _selecting
                  ? Row(
                      children: [
                        Text(
                          '已选 ${_picked.length} 张',
                          style: context.texts.titleMedium!.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _saving ? null : () => _toggleAll(results),
                          child: Text(
                            _picked.length == results.length ? '全不选' : '全选',
                          ),
                        ),
                        TextButton(
                          onPressed: _saving ? null : _exitSelect,
                          child: const Text('完成'),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Text(
                          '全部作品',
                          style: context.texts.titleMedium!.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${results.length} 张',
                          style: context.texts.bodySmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => _enterSelect(),
                          child: const Text('多选'),
                        ),
                      ],
                    ),
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
              ),
              itemCount: results.length,
              itemBuilder: (_, i) {
                final r = results[i];
                return _GridThumb(
                  result: r,
                  selected: !_selecting && r.id == state.selectedId,
                  picked: _selecting && _picked.contains(r.id),
                  selecting: _selecting,
                  onTap: () {
                    if (_selecting) {
                      _toggle(r.id);
                    } else {
                      ref.read(galleryProvider.notifier).select(r.id);
                      Navigator.of(context).pop();
                    }
                  },
                  onLongPress: _selecting
                      ? null
                      : () {
                          Haptics.medium();
                          _enterSelect(r.id);
                        },
                );
              },
            ),
          ),
          // 多选操作栏:进出多选随高度动画滑入滑出
          AnimatedSize(
            duration: Motion.medium,
            curve: Motion.emphasized,
            child: !_selecting
                ? const SizedBox(width: double.infinity)
                : SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: canAct ? _downloadPicked : null,
                              icon: const Icon(Icons.download, size: 19),
                              label: Text(
                                _saving
                                    ? '保存中 $_saveDone/$_saveTotal'
                                    : '保存 (${_picked.length})',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: scheme.errorContainer,
                                foregroundColor: scheme.onErrorContainer,
                              ),
                              onPressed: canAct ? _deletePicked : null,
                              icon: const Icon(Icons.delete_outline, size: 19),
                              label: Text('删除 (${_picked.length})'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _GridThumb extends StatelessWidget {
  const _GridThumb({
    required this.result,
    required this.selected,
    required this.picked,
    required this.selecting,
    required this.onTap,
    this.onLongPress,
  });

  final ResultImage result;

  /// 普通模式:是否为画布当前选中项(主题色描边)。
  final bool selected;

  /// 多选模式:是否已勾选(主题色描边 + 勾选圆标)。
  final bool picked;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final ring = selecting ? picked : selected;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: ring ? scheme.primary : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2.5),
          child: LayoutBuilder(
            builder: (_, c) => Stack(
              children: [
                ResultThumb(
                  result: result,
                  width: c.maxWidth,
                  height: c.maxWidth,
                  radius: 10,
                ),
                // 多选模式左上角换勾选圆标(角标让位)
                if (selecting)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: picked
                            ? scheme.primary
                            : Colors.black.withValues(alpha: .35),
                        border: picked
                            ? null
                            : Border.all(
                                color: Colors.white.withValues(alpha: .85),
                                width: 1.5,
                              ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .25),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: picked
                          ? Icon(Icons.check, size: 15, color: scheme.onPrimary)
                          : null,
                    ),
                  )
                else if (result.badge != ResultBadge.none)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: ResultBadgeChip(badge: result.badge),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
