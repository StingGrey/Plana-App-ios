import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import '../generate/generation_controller.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../inpaint/inpaint_overlay.dart';
import 'gallery_state.dart';
import 'widgets/film_strip.dart';
import 'widgets/result_canvas.dart';

/// 图库页:上方结果画布(大图 + 操作轨 + seed)、下方历史胶片条。
/// 生成链路产出的结果落在这里查看与二次操作。
/// 重绘会话期间 keep-alive:切去其他 tab 再回来,编辑面板(遮罩等)原样保留。
class GalleryPage extends ConsumerStatefulWidget {
  const GalleryPage({super.key});

  @override
  ConsumerState<GalleryPage> createState() => _GalleryPageState();
}

/// 「保存」长按入口的一次性引导:提示过就记在 `settings.json`,不再打扰。
const _kSaveHintKey = 'hint_save_longpress';

class _GalleryPageState extends ConsumerState<GalleryPage>
    with AutomaticKeepAliveClientMixin {
  bool _keep = false;
  bool _hintChecked = false;

  /// 最近一次成功显示的原图字节。切到尚未读盘的老图时先继续画它,
  /// 避免空窗期露占位;新图解码完由 gaplessPlayback 无缝换掉。
  Uint8List? _lastShown;

  @override
  bool get wantKeepAlive => _keep;

  /// 图库里有图了 → 提一次「保存」的长按入口。长按藏得深,不说没人发现。
  /// 每进程只判一次(_hintChecked),真正的"提过没"以落盘的标记为准。
  void _maybeSaveHint(bool hasImage) {
    if (_hintChecked || !hasImage) return;
    _hintChecked = true;
    final prefs = ref.read(prefsStoreProvider);
    if (prefs.get(_kSaveHintKey) != null) return;
    prefs.write(key: _kSaveHintKey, value: '1');
    // build 里不能直接弹 overlay,推到帧后
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        hintSnack(context, '长按「保存」可进入下载设置', icon: Icons.download_outlined);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(galleryProvider);
    final gen = ref.watch(generationProvider);
    final inpaint = ref.watch(inpaintSessionProvider);
    final selected = state.selected;

    // 重绘会话开/关时更新 keep-alive(仅编辑期间常驻,平时随 PageView 回收)
    final keep = inpaint != null;
    if (keep != _keep) {
      _keep = keep;
      updateKeepAlive();
    }

    _maybeSaveHint(!state.isEmpty);

    if (!gen.busy && state.isEmpty && inpaint == null) {
      return const _EmptyGallery();
    }

    // 生成中视角可切换(对齐 web viewingHistory):默认看生成预览,
    // 点历史缩略图切走(生成继续后台跑,进度在胶片条占位卡上),
    // 点占位卡切回。空库时没得切,强制看生成。
    final viewingGen = ref.watch(galleryViewGenProvider);
    final showGen = gen.busy && (viewingGen || selected == null);

    // 大图层:看生成时显预览(未到帧则垫当前选中图);否则显选中结果。
    // 终帧字节与入库字节同一引用 → busy→出图切换零重解码,不闪。
    // 选中图字节不在内存(重启水合/RAM 减负)时按需从盘读,读到前显斜纹。
    var selBytes = selected?.bytes;
    if (selBytes == null && selected != null) {
      selBytes = ref.watch(galleryImageProvider(selected.id)).value;
    }
    // 老图重启后 bytes 不在内存,要异步读原图;这段空窗以前掉回斜纹网格,
    // 就是「老图切换闪一下」的来源。**不能垫缩略图** —— 缩略图是 cover 方形
    // 裁切(256²),拉到全画布会变形又变回去,比斜纹更晃眼(实测反馈)。
    // 改为留住上一张已显示的原图,直到新图解码完成,视觉上完全无缝。
    if (selBytes != null) _lastShown = selBytes;
    final bytes = showGen
        ? (gen.preview ?? selBytes ?? _lastShown)
        : (selBytes ?? _lastShown);
    final w = showGen ? gen.width : (selected?.width ?? 0);
    final h = showGen ? gen.height : (selected?.height ?? 0);
    final showChrome = !showGen && selected != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 大图支持双指缩放/拖动 + 双击放大还原;换图回到 fit,
                  // 生成流式期间不重置。
                  //
                  // imageKey **不能当 widget key 用**:那样「生成中 → 出图」
                  // 会把整棵子树连同 Image 的 State 一起换掉,gaplessPlayback
                  // 失去上一帧,末帧到终图之间空一帧 —— 就是那下闪。改成把它当
                  // 普通字段传下去,在 didUpdateWidget 里重置缩放,widget 原地
                  // 存活,画面连续。
                  if (bytes != null)
                    _ZoomableImage(
                      imageKey: showGen ? 'busy' : (state.selectedId ?? ''),
                      bytes: bytes,
                      width: w,
                      height: h,
                    )
                  else
                    GalleryImageLayer(bytes: bytes, width: w, height: h),
                  // 结果操作层:非生成态淡入,生成时淡出
                  AnimatedOpacity(
                    duration: Motion.medium,
                    curve: Motion.standard,
                    opacity: showChrome ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !showChrome,
                      child: selected != null
                          ? ResultChrome(result: selected)
                          : const SizedBox.shrink(),
                    ),
                  ),
                  // 进度胶囊:渐显+上滑进 / 渐隐+下滑出
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 22,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: Motion.medium,
                        switchInCurve: Motion.emphasized,
                        switchOutCurve: Motion.standard,
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.5),
                              end: Offset.zero,
                            ).animate(anim),
                            child: child,
                          ),
                        ),
                        // 切看历史图时胶囊让位(进度看占位卡),不挡图
                        child: showGen
                            ? ProgressPill(
                                key: const ValueKey('pill'),
                                status: gen,
                              )
                            : const SizedBox.shrink(key: ValueKey('nopill')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            FilmStrip(
              results: state.results,
              selectedId: state.selectedId,
              onSelect: (id) {
                // 生成中点历史图 = 切走看历史(生成继续);平时就是普通选图
                ref.read(galleryViewGenProvider.notifier).set(false);
                ref.read(galleryProvider.notifier).select(id);
              },
              gen: gen.busy ? gen : null,
              genActive: showGen,
              onTapGen: () =>
                  ref.read(galleryViewGenProvider.notifier).set(true),
            ),
          ],
        ),
        // 重绘编辑面板:原地切入覆盖(出入场动画由 overlay 自己编排,
        // 收起动画结束后 session 置空、此层卸载)
        if (inpaint != null)
          InpaintOverlay(key: ObjectKey(inpaint), session: inpaint),
      ],
    );
  }
}

/// 可缩放大图:双指缩放/拖动 + 双击放大(以双击点为焦点)/还原。
/// 缩放态或双指交互中经 [galleryZoomedProvider] 通知 shell 锁 PageView
/// 横滑,避免拖动手势被翻页抢走(不跟手的根源)。
class _ZoomableImage extends ConsumerStatefulWidget {
  const _ZoomableImage({
    required this.imageKey,
    required this.bytes,
    required this.width,
    required this.height,
  });

  /// 当前显示的是哪一张(生成中恒为 'busy',否则是结果 id)。
  /// 变了就把缩放还原到 fit;字节本身逐帧变(流式预览)不算换图。
  final String imageKey;

  final Uint8List bytes;
  final int width;
  final int height;

  @override
  ConsumerState<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends ConsumerState<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: Motion.medium,
  );
  late final CurvedAnimation _zoomCurve = CurvedAnimation(
    parent: _ac,
    curve: Motion.emphasized,
  );
  Animation<Matrix4>? _zoomAnim;
  Offset? _doubleTapPos;
  int _pointers = 0; // 当前按在图上的手指数

  double get _scale => _tc.value.getMaxScaleOnAxis();

  void _setZoomed(bool v) => ref.read(galleryZoomedProvider.notifier).set(v);

  /// 解锁条件:手指全离开 + 未缩放 + 还原动画不在跑。
  void _maybeUnlock() {
    if (_pointers <= 0 && _scale <= 1.02 && !_ac.isAnimating) {
      _setZoomed(false);
    }
  }

  @override
  void initState() {
    super.initState();
    // 只负责「缩放中保持锁」;解锁统一走 _maybeUnlock(避免捏回 1 时
    // 手指还在图上就提前解锁)。
    _tc.addListener(() {
      if (_scale > 1.02) _setZoomed(true);
    });
    _ac.addListener(() {
      final a = _zoomAnim;
      if (a != null) _tc.value = a.value;
    });
    // 双击还原动画结束时手指早已离开,这里补一次解锁检查
    _ac.addStatusListener((s) {
      if (s == AnimationStatus.completed) _maybeUnlock();
    });
  }

  /// 换图:缩放回 fit。以前靠换 widget key 整棵重建来达到同样效果,代价是
  /// 出图那一下会闪(见调用点注释)。
  @override
  void didUpdateWidget(_ZoomableImage old) {
    super.didUpdateWidget(old);
    if (old.imageKey == widget.imageKey) return;
    _ac.stop();
    _zoomAnim = null;
    _tc.value = Matrix4.identity();
    _pointers = 0;
    // didUpdateWidget 在构建期内,同步改 provider 会被 Riverpod 拒掉 ——
    // 与 dispose 同样的理由,推到 microtask。
    final notifier = ref.read(galleryZoomedProvider.notifier);
    Future.microtask(() => notifier.set(false));
  }

  @override
  void dispose() {
    // 切图重建/离屏销毁时解锁横滑;dispose 内不能同步改 provider → microtask
    final notifier = ref.read(galleryZoomedProvider.notifier);
    Future.microtask(() => notifier.set(false));
    _zoomCurve.dispose();
    _ac.dispose();
    _tc.dispose();
    super.dispose();
  }

  /// 双击:已放大 → 动画还原 fit;否则以双击点为焦点放大 2.5×。
  void _onDoubleTap() {
    final Matrix4 target;
    if (_scale > 1.3) {
      target = Matrix4.identity();
    } else {
      final f = _doubleTapPos;
      if (f == null) return;
      const k = 2.5;
      target = Matrix4.identity()
        ..translateByDouble(f.dx, f.dy, 0, 1)
        ..scaleByDouble(k, k, 1, 1)
        ..translateByDouble(-f.dx, -f.dy, 0, 1);
    }
    _zoomAnim = Matrix4Tween(begin: _tc.value, end: target).animate(_zoomCurve);
    _ac.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    // raw pointer 层:手指一碰图即锁翻页(同帧生效,快于手势竞技场
    // 判定,双指落多快都锁得住);全部离手且未缩放才解锁。
    return Listener(
      onPointerDown: (_) {
        _pointers++;
        _setZoomed(true);
      },
      onPointerUp: (_) {
        if (_pointers > 0) _pointers--;
        _maybeUnlock();
      },
      onPointerCancel: (_) {
        if (_pointers > 0) _pointers--;
        _maybeUnlock();
      },
      child: GestureDetector(
        onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
        onDoubleTap: _onDoubleTap,
        child: InteractiveViewer(
          transformationController: _tc,
          maxScale: 10,
          child: GalleryImageLayer(
            bytes: widget.bytes,
            width: widget.width,
            height: widget.height,
          ),
        ),
      ),
    );
  }
}

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery();

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            '还没有作品',
            style: context.texts.titleMedium!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '去「创作」生成第一张',
            style: context.texts.bodySmall!.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}
