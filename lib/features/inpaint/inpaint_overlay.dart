import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/anlas_provider.dart';
import '../../core/theme/app_theme.dart';
import '../gallery/gallery_state.dart';
import '../generate/cost.dart';
import '../generate/generation_controller.dart';
import '../generate/models.dart';
import '../generate/res_rules.dart' show kFreePixelThreshold;
import '../generate/widgets/common.dart' show hintSnack;
import '../shell/shell_state.dart';
import 'inpaint_ops.dart';

/// 内容层功能色(画在图片上,与 app 主题无关):
/// 遮罩紫与 web 一致;裁切青取深档保证浅色底上可读。
const _maskPurple = Color(0xFFA855F7);
const _maskFill = Color(0x8CA855F7); // 遮罩填充 ~55% 紫
// 局部框用 app 主题金(scheme.primary),不硬编码 web 色值。

/// NAI img2img/inpaint 像素上限(与 img2imgResolution 一致)。
const _maxSendPixels = 1024 * 3072;

/// 一次重绘编辑会话:进入编辑器所需的图与参数快照。
class InpaintSession {
  const InpaintSession({required this.imageBytes, required this.input});

  final Uint8List imageBytes;

  /// 参数快照(原图快照或当前创作页状态),重绘沿用其 prompt/角色/vibe 等。
  final GenerateState input;
}

/// 当前重绘会话;非空时图库页原地切入编辑面板(shell 同时锁 tab 切换)。
final inpaintSessionProvider =
    NotifierProvider<InpaintSessionNotifier, InpaintSession?>(
      InpaintSessionNotifier.new,
    );

class InpaintSessionNotifier extends Notifier<InpaintSession?> {
  @override
  InpaintSession? build() => null;

  void open({required Uint8List imageBytes, required GenerateState input}) {
    state = InpaintSession(imageBytes: imageBytes, input: input);
  }

  void close() => state = null;
}

enum _Tool { brush, eraser }

/// 偏位套杆:手指把手与笔刷光标的屏幕间距(手指不挡涂抹点)。
const _assistGapPx = 110.0;

enum _SliderTarget { brush, strength }

enum _CropHandle { move, nw, ne, sw, se }

enum _ExpandHandle { top, bottom, left, right }

/// 重绘编辑面板:嵌在图库页 Stack 顶层原地切入(非路由页)。
/// 涂抹遮罩(8×8 网格)→ 整图/局部 infill;入场=整层渐显+顶栏/面板对滑,
/// 关闭反向收起后由 [inpaintSessionProvider] 置空卸载。
class InpaintOverlay extends ConsumerStatefulWidget {
  const InpaintOverlay({super.key, required this.session});

  final InpaintSession session;

  @override
  ConsumerState<InpaintOverlay> createState() => _InpaintOverlayState();
}

class _InpaintOverlayState extends ConsumerState<InpaintOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: Motion.medium,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _ac,
    curve: Motion.emphasized,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<Offset> _topSlide = Tween(
    begin: const Offset(0, -1.3),
    end: Offset.zero,
  ).animate(_curve);
  late final Animation<Offset> _panelSlide = Tween(
    begin: const Offset(0, 1.1),
    end: Offset.zero,
  ).animate(_curve);

  ui.Image? _img;
  MaskGrid? _grid;
  final List<Uint8List> _undo = [];

  _Tool _tool = _Tool.brush;
  bool _assist = false; // 偏位套杆:光标偏于触点上方,手指不挡涂抹点
  Offset? _fingerAt; // 偏位模式下手指把手位置(图坐标),painter 画杆用
  bool _cropMode = false;
  IntRect? _crop; // 发送框(w/h 恒 64 倍数)
  double _brush = 50; // 笔刷直径(图像素),对齐 web 默认
  double _strength = 0.7;
  _SliderTarget? _slider;
  bool _showOriginal = false;
  bool _firing = false;

  // 扩图模式(对齐 web:四向 padding 恒 64 倍数,发送=白底扩后画布)
  bool _expandMode = false;
  int _padL = 0, _padT = 0, _padR = 0, _padB = 0;
  _ExpandHandle? _expandDrag;
  int _expandStartPad = 0;
  Offset? _expandDragScreen; // 拖拽起点(屏幕坐标;pad 按屏幕位移/scale 折算)
  bool _expandDragMoved = false; // 未移动即抬手 = 点按把手,+64 一个单位
  // 扩图完成后旧图在新图中的位置:「按住对比」按位对齐,新增区露底=遮挡
  Offset _prevImgOffset = Offset.zero;
  Offset _pendingPrevOffset = Offset.zero;

  // 视图变换(图坐标 → 屏幕 = *scale + offset)
  double _scale = 1;
  double _fitScale = 1;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;
  (bool, int, int, int, int)? _fitKey; // 上次 fit 的输入(扩图态+四向 pad)

  // 手势瞬态
  bool _stroking = false;
  Offset? _pendingStroke; // 单指落下、尚未确认为涂抹的起点(防双指第一拍误涂)
  int _rawPointers = 0; // 画布上的真实手指数(raw 事件层)
  bool _pinchSession = false; // 本轮触摸出现过 ≥2 指:余波单指不算涂抹
  Offset? _lastPaint; // 最近落笔点(图坐标),兼作笔刷光标
  int _lastPointers = 0;
  double? _pzScale0;
  Offset? _pzOffset0;
  Offset? _pzFocal0;
  double _pzGesture0 = 1;
  _CropHandle? _cropDrag;
  IntRect? _cropStart;
  Offset? _dragStart; // 拖拽起点(图坐标)

  int _rev = 0; // 遮罩版本号(驱动重绘与 rects 缓存)
  List<ui.Rect>? _rectsCache;
  int _rectsRev = -1;

  // 会话内当前底图:每次重绘完成后替换为新结果(遮罩保留,可连环重抽)
  late Uint8List _currentBytes = widget.session.imageBytes;

  // 上一张底图(重绘前):「按住对比」按住时显示它,与当前结果对照
  ui.Image? _prevImg;

  // 流式预览(仅本编辑器发起的生成;_previewDst 非空 = 生成归属本会话):
  // 预览帧只画进发送目标区,并按发送时的遮罩快照 clip(遮罩区换新、其余原图)
  ui.Image? _previewImg;
  Uint8List? _lastPreviewBytes;
  ui.Rect? _previewDst;
  List<ui.Rect>? _previewClip;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  /// 先解码、图就位后才播入场动画:渐显第一帧画布即完整,避免
  /// 「底色/加载圈 → 图突现」的闪烁。解码失败直接退出会话(防锁死)。
  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.session.imageBytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _img = frame.image;
        _grid = MaskGrid(frame.image.width, frame.image.height);
        // 超出免费分辨率阈值默认开局部,省点数(对齐 web 桌面端)
        if (frame.image.width * frame.image.height > kFreePixelThreshold) {
          _cropMode = true;
          _crop = _defaultCrop(frame.image.width, frame.image.height);
        }
      });
      _ac.forward();
    } catch (_) {
      if (mounted) ref.read(inpaintSessionProvider.notifier).close();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _ac.dispose();
    _img?.dispose();
    _prevImg?.dispose();
    _previewImg?.dispose();
    super.dispose();
  }

  // ---------- 会话内流式生成 ----------

  /// 解码流式预览帧(≈1 帧/秒,主线程解码可承受)。
  Future<void> _decodePreview(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted || _previewDst == null) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _previewImg?.dispose();
        _previewImg = frame.image;
      });
    } catch (_) {
      /* 单帧解码失败直接丢帧 */
    }
  }

  /// 重绘完成:底图换成新结果,遮罩/撤销栈保留(同区可立刻重抽);
  /// 旧底图归档为对比图(「按住对比」显示重绘前)。
  Future<void> _swapImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _prevImg?.dispose();
        _prevImg = _img; // 重绘前的图留作对比
        _prevImgOffset = _pendingPrevOffset; // 扩图时旧图对位 (padL, padT)
        _img = frame.image;
        _currentBytes = bytes;
        // 尺寸变化(扩图完成/异常):重建遮罩,扩展与裁切框归零,视图重新适配
        if (_grid == null ||
            _grid!.imgW != frame.image.width ||
            _grid!.imgH != frame.image.height) {
          _grid = MaskGrid(frame.image.width, frame.image.height);
          _undo.clear();
          _rev++;
          _resetPad();
          _crop = null;
          _cropMode = false;
          _fitKey = null;
          _viewport = Size.zero;
        }
        _clearPreviewState();
      });
    } catch (_) {
      if (mounted) setState(_clearPreviewState);
    }
  }

  void _clearPreviewState() {
    _previewImg?.dispose();
    _previewImg = null;
    _lastPreviewBytes = null;
    _previewDst = null;
    _previewClip = null;
  }

  /// 反向收起后卸载(会话置空)。连点关闭安全:reverse 幂等。
  Future<void> _close() async {
    await _ac.reverse();
    if (mounted) ref.read(inpaintSessionProvider.notifier).close();
  }

  /// 画布光标:涂抹中为最近落笔点;偏位模式下按住未动时也显示悬置光标。
  Offset? get _cursorPoint => _lastPaint ?? (_assist ? _pendingStroke : null);

  List<ui.Rect> get _maskRects {
    if (_rectsRev != _rev || _rectsCache == null) {
      _rectsCache = _grid?.displayRects() ?? const [];
      _rectsRev = _rev;
    }
    return _rectsCache!;
  }

  // ---------- 视图 ----------

  void _fit(Size size) {
    final img = _img;
    if (img == null) return;
    final key = (_expandMode, _padL, _padT, _padR, _padB);
    if (size == _viewport && key == _fitKey) return;
    // 用户未手动缩放(仍在 fit 档)时跟随新 fit 重新居中;
    // 手动缩放过则只更新 fitScale(缩放边界基准),不打断当前视角。
    final wasAtFit = size != _viewport || (_scale - _fitScale).abs() < 1e-9;
    _viewport = size;
    _fitKey = key;
    // 扩图模式:按「图+扩展区」总尺寸适配,四周留出拖拽把手与标签空间
    final cw = (img.width + _padL + _padR).toDouble();
    final ch = (img.height + _padT + _padB).toDouble();
    final margin = _expandMode ? 56.0 : 0.0;
    final availW = math.max(64.0, size.width - margin * 2);
    final availH = math.max(64.0, size.height - margin * 2);
    _fitScale = math.min(availW / cw, availH / ch);
    if (wasAtFit) {
      _scale = _fitScale;
      // 总区域(图坐标系 [-padL, imgW+padR]×[-padT, imgH+padB])居中
      final center = Offset(
        (img.width + _padR - _padL) / 2,
        (img.height + _padB - _padT) / 2,
      );
      _offset = Offset(size.width / 2, size.height / 2) - center * _scale;
    }
  }

  Offset _toImg(Offset local) => (local - _offset) / _scale;

  // ---------- 笔画 ----------

  void _pushUndo() {
    if (_undo.length >= 20) _undo.removeAt(0);
    _undo.add(Uint8List.fromList(_grid!.cells));
  }

  void _beginStroke(Offset p) {
    _pushUndo();
    _stroking = true;
    _grid!.paintDot(p.dx, p.dy, _brush, erase: _tool == _Tool.eraser);
    setState(() {
      _lastPaint = p;
      _rev++;
      _slider = null; // 落笔即收浮动滑杆,给画布让位
    });
  }

  void _strokeTo(Offset p) {
    final from = _lastPaint;
    if (from == null) return;
    _grid!.paintLine(from, p, _brush, erase: _tool == _Tool.eraser);
    setState(() {
      _lastPaint = p;
      _rev++;
    });
  }

  /// 工具钮点击:未选中先选中;已选中的画笔再点切换偏位套杆模式
  /// (橡皮再点不动作;偏位对画笔/橡皮涂抹都生效)。
  void _tapTool(_Tool t) {
    if (_tool != t) {
      setState(() => _tool = t);
      return;
    }
    if (t != _Tool.brush) return;
    HapticFeedback.selectionClick();
    setState(() => _assist = !_assist);
  }

  /// 偏位模式:笔刷光标 = 触点上方 [_assistGapPx](屏幕距离)处。
  Offset _cursorFor(Offset touch) =>
      _assist ? touch - Offset(0, _assistGapPx / _scale) : touch;

  void _endStroke() {
    if (!_stroking) return;
    _stroking = false;
    setState(() => _lastPaint = null);
  }

  void _undoOnce() {
    if (_undo.isEmpty) return;
    _grid!.restore(_undo.removeLast());
    setState(() => _rev++);
  }

  void _clearAll() {
    if (_grid!.isEmpty) return;
    _pushUndo();
    _grid!.clear();
    setState(() => _rev++);
  }

  // ---------- 扩图 ----------

  bool get _hasExpand => _padL + _padT + _padR + _padB > 0;

  void _resetPad() {
    _padL = 0;
    _padT = 0;
    _padR = 0;
    _padB = 0;
  }

  /// 切换涂抹/扩图模式(对齐 web:互斥局部,进出都重置扩展;
  /// 本会话生成进行中不切,防止预览状态错乱)。
  void _setExpandMode(bool on) {
    final img = _img;
    if (img == null || _expandMode == on) return;
    if (_previewDst != null) {
      hintSnack(context, '生成进行中,请稍候', icon: Icons.hourglass_top);
      return;
    }
    if (on && (img.width % 64 != 0 || img.height % 64 != 0)) {
      hintSnack(context, '图片尺寸非 64 对齐,无法扩图', icon: Icons.straighten);
      return;
    }
    setState(() {
      _expandMode = on;
      _resetPad();
      _slider = null;
      _viewport = Size.zero; // 强制重 fit + 居中(web 切换时重置视角同款)
      if (on) {
        _cropMode = false;
        _crop = null;
      }
    });
  }

  int _padOf(_ExpandHandle d) => switch (d) {
    _ExpandHandle.top => _padT,
    _ExpandHandle.bottom => _padB,
    _ExpandHandle.left => _padL,
    _ExpandHandle.right => _padR,
  };

  void _setPadOf(_ExpandHandle d, int v) {
    switch (d) {
      case _ExpandHandle.top:
        _padT = v;
      case _ExpandHandle.bottom:
        _padB = v;
      case _ExpandHandle.left:
        _padL = v;
      case _ExpandHandle.right:
        _padR = v;
    }
  }

  /// 扩图边把手命中(屏幕坐标):整条边外侧条带都可拖(web 拖拽条同款),
  /// 触屏给 48px 命中厚度。
  bool _hitExpand(Offset screenPt) {
    final img = _img;
    if (img == null) return false;
    Offset toScreen(double x, double y) => Offset(x, y) * _scale + _offset;
    final tl = toScreen(-_padL.toDouble(), -_padT.toDouble());
    final br = toScreen(
      (img.width + _padR).toDouble(),
      (img.height + _padB).toDouble(),
    );
    const grab = 48.0;
    final bands = <_ExpandHandle, ui.Rect>{
      _ExpandHandle.top: ui.Rect.fromLTRB(
        tl.dx,
        tl.dy - grab,
        br.dx,
        tl.dy + 8,
      ),
      _ExpandHandle.bottom: ui.Rect.fromLTRB(
        tl.dx,
        br.dy - 8,
        br.dx,
        br.dy + grab,
      ),
      _ExpandHandle.left: ui.Rect.fromLTRB(
        tl.dx - grab,
        tl.dy,
        tl.dx + 8,
        br.dy,
      ),
      _ExpandHandle.right: ui.Rect.fromLTRB(
        br.dx - 8,
        tl.dy,
        br.dx + grab,
        br.dy,
      ),
    };
    for (final e in bands.entries) {
      if (e.value.contains(screenPt)) {
        _expandDrag = e.key;
        _expandStartPad = _padOf(e.key);
        _expandDragScreen = screenPt;
        _expandDragMoved = false;
        return true;
      }
    }
    return false;
  }

  /// 拖拽调整该向 padding:屏幕位移 / scale 折回图像素,
  /// round 到 64 网格(web 同款公式),不小于 0。
  void _updateExpandDrag(Offset screenPt) {
    final dir = _expandDrag;
    final from = _expandDragScreen;
    if (dir == null || from == null) return;
    final d = screenPt - from;
    if (d.distance > 10) _expandDragMoved = true;
    final delta = switch (dir) {
      _ExpandHandle.top => -d.dy,
      _ExpandHandle.bottom => d.dy,
      _ExpandHandle.left => -d.dx,
      _ExpandHandle.right => d.dx,
    };
    final next = math.max(
      0,
      ((_expandStartPad + delta / _scale) / 64).round() * 64,
    );
    if (next != _padOf(dir)) setState(() => _setPadOf(dir, next));
  }

  // ---------- 局部框 ----------

  int _snap64(num v, {int min = 256, required int max}) {
    final capped = math.max(64, max ~/ 64 * 64);
    final lo = math.min(min, capped);
    return ((v / 64).round() * 64).clamp(lo, capped);
  }

  void _toggleCrop() {
    if (_cropMode) {
      setState(() {
        _cropMode = false;
        _crop = null;
      });
      return;
    }
    final img = _img!;
    final tight = tightCropRect(_grid!);
    setState(() {
      _cropMode = true;
      // 有涂抹按遮罩算框;否则给居中默认框,用户自行调整
      _crop = tight != null
          ? alignSendRect(tight, img.width, img.height)
          : _defaultCrop(img.width, img.height);
    });
  }

  /// 居中默认框(约 55% 边长、64 对齐,原点也落 64 网格)。
  IntRect _defaultCrop(int imgW, int imgH) {
    final w = _snap64(imgW * 0.55, max: imgW);
    final h = _snap64(imgH * 0.55, max: imgH);
    return (
      x: (imgW - w) ~/ 2 ~/ 64 * 64,
      y: (imgH - h) ~/ 2 ~/ 64 * 64,
      w: w,
      h: h,
    );
  }

  /// 命中检测:角柄(屏幕 28px)优先,框内为移动;未命中返回 false(落笔涂抹)。
  bool _hitCrop(Offset imgPoint) {
    final c = _crop;
    if (c == null) return false;
    final r = 28 / _scale;
    final corners = <_CropHandle, Offset>{
      _CropHandle.nw: Offset(c.x.toDouble(), c.y.toDouble()),
      _CropHandle.ne: Offset((c.x + c.w).toDouble(), c.y.toDouble()),
      _CropHandle.sw: Offset(c.x.toDouble(), (c.y + c.h).toDouble()),
      _CropHandle.se: Offset((c.x + c.w).toDouble(), (c.y + c.h).toDouble()),
    };
    for (final e in corners.entries) {
      if ((imgPoint - e.value).distance <= r) {
        _cropDrag = e.key;
        _cropStart = c;
        _dragStart = imgPoint;
        return true;
      }
    }
    final rect = ui.Rect.fromLTWH(
      c.x.toDouble(),
      c.y.toDouble(),
      c.w.toDouble(),
      c.h.toDouble(),
    );
    if (rect.contains(imgPoint)) {
      _cropDrag = _CropHandle.move;
      _cropStart = c;
      _dragStart = imgPoint;
      return true;
    }
    return false;
  }

  void _updateCropDrag(Offset imgPoint) {
    final start = _cropStart;
    final from = _dragStart;
    final img = _img;
    if (start == null || from == null || img == null) return;
    final dx = imgPoint.dx - from.dx;
    final dy = imgPoint.dy - from.dy;

    IntRect next;
    switch (_cropDrag!) {
      case _CropHandle.move:
        // 原点吸附 64 网格:发送框 x/y 不对齐会让子图内遮罩相对
        // VAE 网格相位错位,产生块状伪影(web maskCrop 修复同款约束)
        int snapPos(double v, int max) =>
            ((v / 64).round() * 64).clamp(0, math.max(0, max));
        next = (
          x: snapPos(start.x + dx, img.width - start.w),
          y: snapPos(start.y + dy, img.height - start.h),
          w: start.w,
          h: start.h,
        );
      case _CropHandle.nw:
      case _CropHandle.ne:
      case _CropHandle.sw:
      case _CropHandle.se:
        final west = _cropDrag == _CropHandle.nw || _cropDrag == _CropHandle.sw;
        final north =
            _cropDrag == _CropHandle.nw || _cropDrag == _CropHandle.ne;
        // 对角固定:拖动角改变宽高(64 步进),原点随之调整并 clamp。
        final anchorX = west ? start.x + start.w : start.x;
        final anchorY = north ? start.y + start.h : start.y;
        final rawW = west
            ? (anchorX - (start.x + dx))
            : (start.x + start.w + dx - anchorX);
        final rawH = north
            ? (anchorY - (start.y + dy))
            : (start.y + start.h + dy - anchorY);
        final w = _snap64(rawW, max: west ? anchorX : img.width - anchorX);
        final h = _snap64(rawH, max: north ? anchorY : img.height - anchorY);
        next = (
          x: west ? anchorX - w : anchorX,
          y: north ? anchorY - h : anchorY,
          w: w,
          h: h,
        );
    }
    if (next != _crop) setState(() => _crop = next);
  }

  // ---------- 手势 ----------

  void _onScaleStart(ScaleStartDetails d) {
    _lastPointers = d.pointerCount;
    if (d.pointerCount == 1) {
      // 缩放松手余波:先抬一指时 recognizer 会以剩下那指重启手势,
      // 这不是新涂抹——整轮触摸(直到全部离手)不再落笔。
      if (_pinchSession) return;
      if (_expandMode) {
        // 扩图模式不涂抹:单指=拖边把手,未命中则平移画布
        _hitExpand(d.localFocalPoint);
        return;
      }
      final p = _toImg(d.localFocalPoint);
      if (_cropMode && _hitCrop(p)) return;
      // 不立即落笔:双指缩放时第一指总会先到一拍,等移动/抬手再确认涂抹
      _pendingStroke = _cursorFor(p);
      if (_assist) setState(() => _fingerAt = p); // 立即显示把手与偏位光标
    } else {
      _pendingStroke = null;
      _pzScale0 = null; // update 首帧 rebase
    }
  }

  void _rebasePZ(ScaleUpdateDetails d) {
    _pzScale0 = _scale;
    _pzOffset0 = _offset;
    _pzFocal0 = d.localFocalPoint;
    _pzGesture0 = d.scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      _pendingStroke = null; // 第二指到:确认缩放,悬置起点作废
      _fingerAt = null;
      if (_stroking) _endStroke();
      _cropDrag = null;
      _expandDrag = null;
      if (_lastPointers < 2 || _pzScale0 == null) _rebasePZ(d);
      final k = d.scale / _pzGesture0;
      final ns = (_pzScale0! * k).clamp(_fitScale * 0.5, _fitScale * 10.0);
      final ratio = ns / _pzScale0!;
      setState(() {
        _offset = d.localFocalPoint - (_pzFocal0! - _pzOffset0!) * ratio;
        _scale = ns;
      });
    } else if (_expandDrag != null) {
      _updateExpandDrag(d.localFocalPoint);
    } else if (_expandMode) {
      // 扩图模式单指未命中把手:平移画布
      if (d.focalPointDelta != Offset.zero) {
        setState(() => _offset += d.focalPointDelta);
      }
    } else if (_cropDrag != null) {
      _updateCropDrag(_toImg(d.localFocalPoint));
    } else {
      final touch = _toImg(d.localFocalPoint);
      if (_assist) _fingerAt = touch; // 把手随指(strokeTo 的 setState 一并刷新)
      // 仍是单指且开始移动:确认涂抹,先补落悬置起点
      final pending = _pendingStroke;
      if (pending != null) {
        _pendingStroke = null;
        _beginStroke(pending);
      }
      if (_stroking) _strokeTo(_cursorFor(touch));
    }
    _lastPointers = d.pointerCount;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    // 单指按下即抬(点涂一个点):抬手时落笔
    final pending = _pendingStroke;
    _pendingStroke = null;
    if (pending != null && _lastPointers == 1 && d.pointerCount == 0) {
      _beginStroke(pending);
    }
    _endStroke();
    if (_fingerAt != null) setState(() => _fingerAt = null);
    _cropDrag = null;
    // 点按把手(按下未拖动即抬手):该向 +64 一个单位
    final tapDir = _expandDrag;
    if (tapDir != null && !_expandDragMoved && d.pointerCount == 0) {
      HapticFeedback.selectionClick();
      setState(() => _setPadOf(tapDir, _padOf(tapDir) + 64));
    }
    _expandDrag = null;
    _expandDragScreen = null;
    _pzScale0 = null;
  }

  // ---------- 发起重绘 ----------

  ({int w, int h}) get _sendSize {
    final img = _img;
    if (img == null) return (w: 0, h: 0);
    if (_expandMode) {
      return (w: img.width + _padL + _padR, h: img.height + _padT + _padB);
    }
    final c = _cropMode ? _crop : null;
    return (w: c?.w ?? img.width, h: c?.h ?? img.height);
  }

  /// 扩图发送:白底扩后画布 + 自动 mask(原图区黑/新增区白),
  /// paste 置空 → 结果即完整新图直接入库(尺寸=params 扩后尺寸)。
  Future<void> _fireExpand(ui.Image img) async {
    final tw = img.width + _padL + _padR;
    final th = img.height + _padT + _padB;
    if (tw * th > _maxSendPixels) {
      hintSnack(
        context,
        '扩图后尺寸过大,请缩小扩展范围',
        icon: Icons.photo_size_select_large,
      );
      return;
    }
    setState(() => _firing = true);
    try {
      final image = await buildExpandImage(
        _currentBytes,
        padL: _padL,
        padT: _padT,
        padR: _padR,
        padB: _padB,
      );
      final mask = await buildExpandMask(
        imgW: img.width,
        imgH: img.height,
        padL: _padL,
        padT: _padT,
        padR: _padR,
        padB: _padB,
      );
      final snapshot = widget.session.input.copyWith(
        inpaint: InpaintJob(image: image, mask: mask, strength: _strength),
        img2img: null,
        params: widget.session.input.params.copyWith(
          width: tw,
          height: th,
          seed: '',
        ),
      );
      if (!mounted) return;
      // 完成换底图后旧图落位 (padL, padT);预览帧直接铺满扩后区域
      _pendingPrevOffset = Offset(_padL.toDouble(), _padT.toDouble());
      setState(() {
        _previewDst = ui.Rect.fromLTWH(
          -_padL.toDouble(),
          -_padT.toDouble(),
          tw.toDouble(),
          th.toDouble(),
        );
        _previewClip = null;
      });
      ref.read(generationProvider.notifier).generate(using: snapshot);
    } finally {
      if (mounted) setState(() => _firing = false);
    }
  }

  Future<void> _fire() async {
    final img = _img;
    final grid = _grid;
    if (img == null || grid == null || _firing) return;
    if (ref.read(generationProvider).busy) {
      hintSnack(context, '生成进行中,请稍后再试', icon: Icons.hourglass_top);
      return;
    }
    if (_expandMode) {
      if (!_hasExpand) {
        hintSnack(context, '先拖动边缘扩展画布', icon: Icons.open_in_full);
        return;
      }
      await _fireExpand(img);
      return;
    }
    if (grid.isEmpty) {
      hintSnack(context, '先用画笔涂抹要重绘的区域', icon: Icons.brush);
      return;
    }
    final send = _cropMode ? _crop : null;
    if (send != null && !grid.hasCellsIn(send)) {
      hintSnack(context, '黄框内没有涂抹区域', icon: Icons.crop);
      return;
    }
    final sw = send?.w ?? img.width;
    final sh = send?.h ?? img.height;
    if (sw * sh > _maxSendPixels) {
      hintSnack(
        context,
        '发送尺寸过大,请开启「局部」缩小范围',
        icon: Icons.photo_size_select_large,
      );
      return;
    }
    if (send == null && (img.width % 64 != 0 || img.height % 64 != 0)) {
      hintSnack(context, '图片尺寸非 64 对齐,请使用「局部」模式', icon: Icons.straighten);
      return;
    }

    setState(() => _firing = true);
    try {
      final Uint8List image;
      final Uint8List mask;
      InpaintPaste? paste;
      if (send != null) {
        image = await cropPng(_currentBytes, send);
        mask = await maskToPng(grid, region: send);
        paste = InpaintPaste(
          original: _currentBytes,
          sendX: send.x,
          sendY: send.y,
          tightX: send.x,
          tightY: send.y,
          tightW: send.w,
          tightH: send.h,
          outW: img.width,
          outH: img.height,
        );
      } else {
        image = _currentBytes;
        mask = await maskToPng(grid);
      }
      final snapshot = widget.session.input.copyWith(
        inpaint: InpaintJob(
          image: image,
          mask: mask,
          strength: _strength,
          paste: paste,
        ),
        img2img: null,
        params: widget.session.input.params.copyWith(
          width: sw,
          height: sh,
          seed: '',
        ),
      );
      if (!mounted) return;
      // 留在编辑器内流式预览:记录预览目标区 + 发送时遮罩快照
      // (遮罩区换新内容、其余保持原图;完成后换底图、遮罩保留)
      _pendingPrevOffset = Offset.zero;
      setState(() {
        _previewDst = send != null
            ? ui.Rect.fromLTWH(
                send.x.toDouble(),
                send.y.toDouble(),
                send.w.toDouble(),
                send.h.toDouble(),
              )
            : ui.Rect.fromLTWH(
                0,
                0,
                img.width.toDouble(),
                img.height.toDouble(),
              );
        _previewClip = List.of(_maskRects);
      });
      ref.read(generationProvider.notifier).generate(using: snapshot);
    } finally {
      if (mounted) setState(() => _firing = false);
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final img = _img;
    final gen = ref.watch(generationProvider);

    // 会话内生成跟踪(_previewDst 非空 = 本编辑器发起):
    // 预览帧解码 → 画布混合;完成 → 换底图保留遮罩;失败 → 清预览。
    ref.listen<GenStatus>(generationProvider, (prev, next) {
      if (_previewDst == null) return;
      final preview = next.preview;
      if (next.busy &&
          preview != null &&
          !identical(preview, _lastPreviewBytes)) {
        _lastPreviewBytes = preview;
        _decodePreview(preview);
      }
      if ((prev?.busy ?? false) && !next.busy) {
        if (next.error == null) {
          final results = ref.read(galleryProvider).results;
          final latest = results.isEmpty ? null : results.first;
          final bytes = latest?.bytes;
          if (bytes != null) {
            _swapImage(bytes);
          } else {
            setState(_clearPreviewState);
          }
        } else {
          setState(_clearPreviewState);
        }
      }
    });
    final isOpus = ref.watch(anlasProvider).asData?.value?.isOpus ?? false;
    final send = _sendSize;
    final cost = img == null
        ? 0
        : estimateInpaintCost(
            widget.session.input,
            isOpus: isOpus,
            sendW: send.w,
            sendH: send.h,
            strength: _strength,
          );
    final hasPrev = _prevImg != null; // 至少重绘过一次才有「前后对比」
    // 编辑中允许切 tab(图库页 keep-alive 保留本面板);仅当图库可见时
    // 返回键收面板,在其他 tab 返回键走系统默认(最小化)。
    final onGallery = ref.watch(shellIndexProvider) == 1;

    return PopScope(
      canPop: !onGallery,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: IgnorePointer(
        // 解码/入场前全透明,不拦下层图库的触摸
        ignoring: img == null,
        child: FadeTransition(
          opacity: _curve,
          child: ColoredBox(
            color: scheme.surface,
            child: Column(
              children: [
                SlideTransition(
                  position: _topSlide,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(
                      children: [
                        _RoundBtn(icon: Icons.close, onTap: _close),
                        const SizedBox(width: 12),
                        Expanded(child: _buildSegTabs()),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRect(
                    child: ColoredBox(
                      // 与图库画布同底色,原地切换视觉连续
                      color: scheme.surfaceContainerHigh,
                      child: img == null
                          ? const Center(child: CircularProgressIndicator())
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                _fit(constraints.biggest);
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Listener(
                                      // raw 层手指计数:标记双指会话(其
                                      // 余波单指重启不算涂抹),全离手复位
                                      onPointerDown: (_) {
                                        _rawPointers++;
                                        if (_rawPointers >= 2) {
                                          _pinchSession = true;
                                        }
                                      },
                                      onPointerUp: (_) {
                                        if (_rawPointers > 0) _rawPointers--;
                                        if (_rawPointers == 0) {
                                          _pinchSession = false;
                                        }
                                      },
                                      onPointerCancel: (_) {
                                        if (_rawPointers > 0) _rawPointers--;
                                        if (_rawPointers == 0) {
                                          _pinchSession = false;
                                        }
                                      },
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onScaleStart: _onScaleStart,
                                        onScaleUpdate: _onScaleUpdate,
                                        onScaleEnd: _onScaleEnd,
                                        child: CustomPaint(
                                          painter: _CanvasPainter(
                                            // 按住对比:显示重绘前的底图
                                            // (扩图后旧图对位,新增区露画布底=遮挡)
                                            image:
                                                _showOriginal &&
                                                    _prevImg != null
                                                ? _prevImg!
                                                : img,
                                            imageOffset:
                                                _showOriginal &&
                                                    _prevImg != null
                                                ? _prevImgOffset
                                                : Offset.zero,
                                            rects: _showOriginal
                                                ? const []
                                                : _maskRects,
                                            rev: _rev,
                                            scale: _scale,
                                            offset: _offset,
                                            crop: _showOriginal ? null : _crop,
                                            cropActive: _cropMode,
                                            // 扩图可视化(生成中/对比中隐藏)
                                            expandUi:
                                                _expandMode &&
                                                _previewDst == null &&
                                                !_showOriginal,
                                            padL: _padL,
                                            padT: _padT,
                                            padR: _padR,
                                            padB: _padB,
                                            cursor: _showOriginal
                                                ? null
                                                : _cursorPoint,
                                            finger: _showOriginal
                                                ? null
                                                : _fingerAt,
                                            brush: _brush,
                                            erasing: _tool == _Tool.eraser,
                                            // 框用主题浅金(容器色),
                                            // 外缘黑描边兜底可读性
                                            accent: scheme.primaryContainer,
                                            onAccent: scheme.onPrimaryContainer,
                                            preview: _showOriginal
                                                ? null
                                                : _previewImg,
                                            previewDst: _previewDst,
                                            previewClip: _previewClip,
                                          ),
                                        ),
                                      ),
                                    ),
                                    // 对比按钮与浮动滑杆同踞下缘,滑杆展开时让位
                                    if (hasPrev && _slider == null)
                                      Positioned(
                                        right: 14,
                                        bottom: 14,
                                        child: _CompareButton(
                                          onChanged: (v) =>
                                              setState(() => _showOriginal = v),
                                        ),
                                      ),
                                    // 浮动滑杆(笔刷/强度):悬浮画布下缘,不顶布局
                                    Positioned(
                                      left: 14,
                                      right: 14,
                                      bottom: 12,
                                      child: AnimatedSwitcher(
                                        duration: Motion.fast,
                                        switchInCurve: Curves.easeOutCubic,
                                        switchOutCurve: Curves.easeIn,
                                        transitionBuilder: (child, anim) =>
                                            FadeTransition(
                                              opacity: anim,
                                              child: SlideTransition(
                                                position: Tween<Offset>(
                                                  begin: const Offset(0, .3),
                                                  end: Offset.zero,
                                                ).animate(anim),
                                                child: child,
                                              ),
                                            ),
                                        child: _slider == null
                                            ? const SizedBox.shrink(
                                                key: ValueKey('noslider'),
                                              )
                                            : KeyedSubtree(
                                                key: ValueKey(_slider),
                                                child: _buildSliderRow(),
                                              ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                    ),
                  ),
                ),
                SlideTransition(
                  position: _panelSlide,
                  child: _buildBottomPanel(gen, cost),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSegTabs() {
    final scheme = context.scheme;
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _SegTab(
            icon: Icons.brush,
            label: '涂抹',
            active: !_expandMode,
            onTap: () => _setExpandMode(false),
          ),
          _SegTab(
            icon: Icons.open_in_full,
            label: '扩图',
            active: _expandMode,
            onTap: () => _setExpandMode(true),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomPanel(GenStatus gen, int cost) {
    if (_expandMode) return _buildExpandPanel(gen, cost);
    final scheme = context.scheme;
    final grid = _grid;
    final canUndo = _undo.isNotEmpty;
    final canClear = !(grid?.isEmpty ?? true);
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ToolBtn(
                  icon: _assist ? Icons.my_location : Icons.brush,
                  label: _assist ? '偏位' : '画笔',
                  active: _tool == _Tool.brush,
                  onTap: () => _tapTool(_Tool.brush),
                ),
                _ToolBtn(
                  icon: Icons.cleaning_services,
                  label: '橡皮',
                  active: _tool == _Tool.eraser,
                  onTap: () => _tapTool(_Tool.eraser),
                ),
                _ToolBtn(
                  icon: Icons.crop,
                  label: '局部',
                  active: _cropMode,
                  onTap: _toggleCrop,
                ),
                _ToolBtn(
                  icon: Icons.undo,
                  label: '撤销',
                  enabled: canUndo,
                  onTap: _undoOnce,
                ),
                _ToolBtn(
                  icon: Icons.restart_alt,
                  label: '清空',
                  enabled: canClear,
                  tint: scheme.error,
                  onTap: _clearAll,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _ParamChip(
                  icon: Icons.line_weight,
                  label: '笔刷',
                  value: '${_brush.round()}',
                  active: _slider == _SliderTarget.brush,
                  onTap: () => setState(
                    () => _slider = _slider == _SliderTarget.brush
                        ? null
                        : _SliderTarget.brush,
                  ),
                ),
                const SizedBox(width: 8),
                _ParamChip(
                  icon: Icons.tune,
                  label: '强度',
                  value: _strength.toStringAsFixed(2),
                  active: _slider == _SliderTarget.strength,
                  onTap: () => setState(
                    () => _slider = _slider == _SliderTarget.strength
                        ? null
                        : _SliderTarget.strength,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: _buildCtaArea(gen, cost, label: '重绘'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 扩图专属底面板:尺寸(点击弹窗直接输入)/强度/重置 + 全宽 CTA。
  Widget _buildExpandPanel(GenStatus gen, int cost) {
    final scheme = context.scheme;
    final img = _img;
    final tw = img == null ? 0 : img.width + _padL + _padR;
    final th = img == null ? 0 : img.height + _padT + _padB;
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _ParamChip(
                  icon: Icons.aspect_ratio,
                  label: '尺寸',
                  value: '$tw×$th',
                  active: _hasExpand,
                  onTap: _editExpandSize,
                ),
                const SizedBox(width: 8),
                _ParamChip(
                  icon: Icons.tune,
                  label: '强度',
                  value: _strength.toStringAsFixed(2),
                  active: _slider == _SliderTarget.strength,
                  onTap: () => setState(
                    () => _slider = _slider == _SliderTarget.strength
                        ? null
                        : _SliderTarget.strength,
                  ),
                ),
                const Spacer(),
                Material(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(13),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _hasExpand ? () => setState(_resetPad) : null,
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: Icon(
                        Icons.restart_alt,
                        size: 20,
                        color: _hasExpand
                            ? scheme.error
                            : scheme.onSurfaceVariant.withValues(alpha: .35),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 46,
              width: double.infinity,
              child: _buildCtaArea(
                gen,
                cost,
                label: '扩图',
                disabled: !_hasExpand,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 生成 CTA / 生成中进度条(涂抹与扩图面板共用)。
  Widget _buildCtaArea(
    GenStatus gen,
    int cost, {
    required String label,
    bool disabled = false,
  }) {
    final scheme = context.scheme;
    if (gen.busy) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: Stack(
          fit: StackFit.expand,
          children: [
            LinearProgressIndicator(
              value: gen.progress,
              backgroundColor: scheme.surfaceContainerHigh,
              color: scheme.primary.withValues(alpha: .38),
            ),
            Center(
              child: Text(
                gen.progress != null
                    ? '${gen.step} / ${gen.total}'
                    : (gen.note ?? '生成中…'),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return FilledButton(
      style: FilledButton.styleFrom(
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
      ),
      onPressed: _firing || disabled ? null : _fire,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_firing)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onPrimary.withValues(alpha: .8),
              ),
            )
          else
            const Icon(Icons.auto_awesome, size: 18),
          const SizedBox(width: 7),
          Text(
            _firing ? '准备中…' : label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          if (!_firing) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.onPrimary.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                cost == 0 ? '免费' : '$cost Anlas',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 扩图尺寸弹窗:输入/步进目标分辨率(controller 生命周期归弹窗
  /// StatefulWidget 管,退场动画期间仍存活,勿在 await 后立刻 dispose)。
  /// 结果 round 到 64 网格、不小于原图,增量按 64 单位对称分配到两侧
  /// (奇数单位多余的一格给右/下)。
  Future<void> _editExpandSize() async {
    final img = _img;
    if (img == null) return;
    final res = await showDialog<({int w, int h})>(
      context: context,
      builder: (_) => _ExpandSizeDialog(
        initW: img.width + _padL + _padR,
        initH: img.height + _padT + _padB,
        minW: img.width,
        minH: img.height,
      ),
    );
    if (res == null || !mounted) return;
    final tw = math.max(img.width, (res.w / 64).round() * 64);
    final th = math.max(img.height, (res.h / 64).round() * 64);
    final ux = (tw - img.width) ~/ 64;
    final uy = (th - img.height) ~/ 64;
    setState(() {
      _padL = ux ~/ 2 * 64;
      _padR = (ux - ux ~/ 2) * 64;
      _padT = uy ~/ 2 * 64;
      _padB = (uy - uy ~/ 2) * 64;
    });
  }

  Widget _buildSliderRow() {
    final scheme = context.scheme;
    final isBrush = _slider == _SliderTarget.brush;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .85),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .14),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Text(
            isBrush ? '笔刷大小' : '重绘强度',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          Expanded(
            child: isBrush
                ? Slider(
                    value: _brush,
                    min: 5, // 对齐 web 桌面端(5–200)
                    max: 200,
                    onChanged: (v) => setState(() => _brush = v),
                  )
                : Slider(
                    value: _strength,
                    min: 0.1,
                    max: 1.0,
                    divisions: 90,
                    onChanged: (v) => setState(() => _strength = v),
                  ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              isBrush ? '${_brush.round()}' : _strength.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 画布 ----------

class _CanvasPainter extends CustomPainter {
  const _CanvasPainter({
    required this.image,
    required this.rects,
    required this.rev,
    required this.scale,
    required this.offset,
    required this.crop,
    required this.cropActive,
    required this.cursor,
    required this.finger,
    required this.brush,
    required this.erasing,
    required this.accent,
    required this.onAccent,
    this.imageOffset = Offset.zero,
    this.expandUi = false,
    this.padL = 0,
    this.padT = 0,
    this.padR = 0,
    this.padB = 0,
    this.preview,
    this.previewDst,
    this.previewClip,
  });

  final ui.Image image;
  final List<ui.Rect> rects;
  final int rev;
  final double scale;
  final Offset offset;
  final IntRect? crop;
  final bool cropActive;
  final Offset? cursor; // 图坐标;非空时画笔刷光标(网格方块)
  final Offset? finger; // 偏位套杆的手指把手位置;非空时画把手+连杆
  final double brush;
  final bool erasing;
  final Color accent; // 局部框/标签主题色(scheme.primary)
  final Color onAccent; // 标签文字色(scheme.onPrimary)

  /// 底图绘制偏移:扩图完成后「按住对比」把旧图对位到 (padL, padT),
  /// 新增区露出画布底色即天然遮挡(web 用深底遮新增区,同义)。
  final Offset imageOffset;

  /// 扩图可视化(新增区棋盘/虚线框/四边把手/尺寸标签)。
  final bool expandUi;
  final int padL, padT, padR, padB;

  /// 流式预览帧:clip 到发送时的遮罩快照后画进 [previewDst]
  /// (遮罩区换新内容、其余保持原图,对齐 web 的 mask 混合预览)。
  final ui.Image? preview;
  final ui.Rect? previewDst;
  final List<ui.Rect>? previewClip;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(
        imageOffset.dx,
        imageOffset.dy,
        image.width.toDouble(),
        image.height.toDouble(),
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );

    if (expandUi) _paintExpandZones(canvas);

    // 流式预览:遮罩区显示新内容(clip 遮罩快照),其余保持原图;
    // 预览期间不再蒙紫,免得挡住效果。
    final pv = preview;
    final dst = previewDst;
    if (pv != null && dst != null) {
      canvas.save();
      final clip = previewClip;
      if (clip != null && clip.isNotEmpty) {
        final path = Path();
        for (final r in clip) {
          path.addRect(r);
        }
        canvas.clipPath(path);
      }
      canvas.drawImageRect(
        pv,
        ui.Rect.fromLTWH(0, 0, pv.width.toDouble(), pv.height.toDouble()),
        dst,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    } else if (rects.isNotEmpty) {
      // 遮罩(紫,50%+)
      final p = Paint()..color = _maskFill;
      for (final r in rects) {
        canvas.drawRect(r, p);
      }
    }

    // 局部裁切框(对齐 web:框外 40% 暗化 + 三分构图线 + 外黑内黄双描边)
    final c = crop;
    if (c != null && cropActive) {
      final rect = ui.Rect.fromLTWH(
        c.x.toDouble(),
        c.y.toDouble(),
        c.w.toDouble(),
        c.h.toDouble(),
      );
      final iw = image.width.toDouble();
      final ih = image.height.toDouble();
      final dim = Paint()..color = const Color(0x66000000);
      canvas.drawRect(ui.Rect.fromLTRB(0, 0, iw, rect.top), dim);
      canvas.drawRect(ui.Rect.fromLTRB(0, rect.bottom, iw, ih), dim);
      canvas.drawRect(
        ui.Rect.fromLTRB(0, rect.top, rect.left, rect.bottom),
        dim,
      );
      canvas.drawRect(
        ui.Rect.fromLTRB(rect.right, rect.top, iw, rect.bottom),
        dim,
      );

      // 三分构图辅助线(主题色低透明)
      final third = Paint()
        ..color = accent.withValues(alpha: .22)
        ..strokeWidth = 1 / scale;
      for (var i = 1; i <= 2; i++) {
        final lx = rect.left + rect.width * i / 3;
        final ly = rect.top + rect.height * i / 3;
        canvas.drawLine(Offset(lx, rect.top), Offset(lx, rect.bottom), third);
        canvas.drawLine(Offset(rect.left, ly), Offset(rect.right, ly), third);
      }

      // 框:外缘黑 + 内层主题金(实线,层次同 web)
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0x99000000)
          ..strokeWidth = 5 / scale,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = accent
          ..strokeWidth = 2.4 / scale,
      );

      // 四角 L 柄:黑影垫底 + 主题黄
      final len = 15 / scale;
      void corners(Paint p) {
        void corner(Offset at, double sx, double sy) {
          canvas.drawLine(at, at + Offset(len * sx, 0), p);
          canvas.drawLine(at, at + Offset(0, len * sy), p);
        }

        corner(rect.topLeft, 1, 1);
        corner(rect.topRight, -1, 1);
        corner(rect.bottomLeft, 1, -1);
        corner(rect.bottomRight, -1, -1);
      }

      corners(
        Paint()
          ..color = Colors.black.withValues(alpha: .55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6.5 / scale
          ..strokeCap = StrokeCap.round,
      );
      corners(
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 / scale
          ..strokeCap = StrokeCap.round,
      );
    }

    // 笔刷光标(虚线方框,与落格网格严格一致;橡皮用深色描边)
    ui.Rect? cursorRect;
    if (cursor != null) {
      final p = Paint()
        ..color = erasing ? Colors.black54 : _maskPurple.withValues(alpha: .9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 / scale;
      final gridCount = math.max(1, (brush / 8).round());
      final half = gridCount ~/ 2;
      final gx = ((cursor!.dx / 8).floor() - half) * 8.0;
      final gy = ((cursor!.dy / 8).floor() - half) * 8.0;
      cursorRect = ui.Rect.fromLTWH(gx, gy, gridCount * 8.0, gridCount * 8.0);
      canvas.drawPath(
        _dashPath(Path()..addRect(cursorRect), 6 / scale, 5 / scale),
        p,
      );
    }

    // 偏位套杆:手指把手圆 + 连到光标框的杆(黑外影+白线,任意底可读)
    if (finger != null && cursor != null && cursorRect != null) {
      final handleR = 30 / scale;
      void stroke(Paint p) {
        canvas.drawCircle(finger!, handleR, p);
        final dir = cursor! - finger!;
        final len = dir.distance;
        if (len > handleR) {
          final unit = dir / len;
          canvas.drawLine(
            finger! + unit * handleR,
            cursor! - unit * (cursorRect!.width / 2),
            p,
          );
        }
      }

      stroke(
        Paint()
          ..color = Colors.black.withValues(alpha: .28)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 / scale,
      );
      stroke(
        Paint()
          ..color = Colors.white.withValues(alpha: .92)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8 / scale,
      );
      canvas.drawCircle(
        finger!,
        handleR,
        Paint()..color = Colors.white.withValues(alpha: .10),
      );
    }

    canvas.restore();

    // 屏幕空间:裁切尺寸标签(框左上角上方)
    if (c != null && cropActive) {
      _screenLabel(
        canvas,
        '裁切  ${c.w}×${c.h}',
        Offset(offset.dx + c.x * scale, offset.dy + c.y * scale - 26),
      );
    }

    if (expandUi) _paintExpandHandles(canvas);
  }

  /// 图空间的扩图可视化:新增区白底 + 主题色棋盘(将被生成填充的区域),
  /// 扩后总区虚线框(黑影垫底,层次同局部框);未拖出扩展时画图缘淡虚线提示。
  void _paintExpandZones(Canvas canvas) {
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    final total = ui.Rect.fromLTRB(
      -padL.toDouble(),
      -padT.toDouble(),
      iw + padR,
      ih + padB,
    );
    final hasPad = padL + padT + padR + padB > 0;
    if (hasPad) {
      final zones = <ui.Rect>[
        if (padT > 0) ui.Rect.fromLTRB(total.left, total.top, total.right, 0),
        if (padB > 0)
          ui.Rect.fromLTRB(total.left, ih, total.right, total.bottom),
        if (padL > 0) ui.Rect.fromLTRB(total.left, 0, 0, ih),
        if (padR > 0) ui.Rect.fromLTRB(iw, 0, total.right, ih),
      ];
      final base = Paint()..color = Colors.white;
      final check = Paint()..color = accent.withValues(alpha: .5);
      final cell = 14 / scale; // 棋盘块按屏幕尺寸恒定(对齐 web css 背景)
      for (final z in zones) {
        canvas.drawRect(z, base);
        _checker(canvas, z, cell, check);
      }
      final dashed = _dashPath(Path()..addRect(total), 7 / scale, 5 / scale);
      canvas.drawPath(
        dashed,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0x77000000)
          ..strokeWidth = 4.5 / scale,
      );
      canvas.drawPath(
        dashed,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = accent
          ..strokeWidth = 2.2 / scale,
      );
    } else {
      final dashed = _dashPath(Path()..addRect(total), 7 / scale, 5 / scale);
      canvas.drawPath(
        dashed,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = accent.withValues(alpha: .6)
          ..strokeWidth = 2 / scale,
      );
    }
  }

  /// 屏幕空间的扩图把手(四边中点外侧,固定屏幕尺寸)与总尺寸标签:
  /// 把手内容 = 该向 padding 数值(>0)或朝外双 chevron(=0,提示可拖)。
  void _paintExpandHandles(Canvas canvas) {
    Offset ts(double x, double y) =>
        Offset(x * scale + offset.dx, y * scale + offset.dy);
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    final tl = ts(-padL.toDouble(), -padT.toDouble());
    final br = ts(iw + padR, ih + padB);
    final cx = (tl.dx + br.dx) / 2;
    final cy = (tl.dy + br.dy) / 2;
    const gap = 12.0;

    final handles = <({Offset c, bool horiz, Offset out})>[
      (c: Offset(cx, tl.dy - gap - 13), horiz: true, out: const Offset(0, -1)),
      (c: Offset(cx, br.dy + gap + 13), horiz: true, out: const Offset(0, 1)),
      (c: Offset(tl.dx - gap - 13, cy), horiz: false, out: const Offset(-1, 0)),
      (c: Offset(br.dx + gap + 13, cy), horiz: false, out: const Offset(1, 0)),
    ];
    for (final h in handles) {
      final rect = ui.Rect.fromCenter(
        center: h.c,
        width: h.horiz ? 60 : 26,
        height: h.horiz ? 26 : 60,
      );
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(13));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.black.withValues(alpha: .30)
          ..strokeWidth = 3.5,
      );
      canvas.drawRRect(rr, Paint()..color = accent);
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.black.withValues(alpha: .12)
          ..strokeWidth = 1,
      );
      // 恒显朝外双 chevron(数值反馈交给底部尺寸 chip)
      final perp = h.horiz ? const Offset(1, 0) : const Offset(0, 1);
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..color = onAccent
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      void chev(Offset tip) {
        final a = tip - h.out * 5 + perp * 5;
        final b = tip - h.out * 5 - perp * 5;
        canvas.drawPath(
          Path()
            ..moveTo(a.dx, a.dy)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo(b.dx, b.dy),
          p,
        );
      }

      chev(h.c + h.out * 5.5);
      chev(h.c - h.out * 0.5);
    }
  }

  /// 屏幕空间胶囊标签(主题色底 + 反色字),裁切/扩图尺寸共用。
  void _screenLabel(Canvas canvas, String text, Offset pos) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: onAccent,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = RRect.fromRectAndRadius(
      ui.Rect.fromLTWH(pos.dx, pos.dy - 4, tp.width + 16, 22),
      const Radius.circular(5),
    );
    canvas.drawRRect(r, Paint()..color = accent);
    tp.paint(canvas, pos + const Offset(8, -1));
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.image != image ||
      old.imageOffset != imageOffset ||
      old.rev != rev ||
      old.scale != scale ||
      old.offset != offset ||
      old.crop != crop ||
      old.cropActive != cropActive ||
      old.expandUi != expandUi ||
      old.padL != padL ||
      old.padT != padT ||
      old.padR != padR ||
      old.padB != padB ||
      old.cursor != cursor ||
      old.finger != finger ||
      old.brush != brush ||
      old.erasing != erasing ||
      old.accent != accent ||
      old.preview != preview ||
      old.previewDst != previewDst;
}

/// 棋盘格填充(隔格绘制),cell 为图空间尺寸。
void _checker(ui.Canvas canvas, ui.Rect r, double cell, Paint p) {
  canvas.save();
  canvas.clipRect(r);
  final x0 = (r.left / cell).floor();
  final x1 = (r.right / cell).ceil();
  final y0 = (r.top / cell).floor();
  final y1 = (r.bottom / cell).ceil();
  for (var gy = y0; gy < y1; gy++) {
    for (var gx = x0; gx < x1; gx++) {
      if ((gx + gy).isEven) {
        canvas.drawRect(ui.Rect.fromLTWH(gx * cell, gy * cell, cell, cell), p);
      }
    }
  }
  canvas.restore();
}

/// 把路径虚线化(按弧长步进抽段)。
Path _dashPath(Path src, double dash, double gap) {
  final out = Path();
  for (final metric in src.computeMetrics()) {
    var d = 0.0;
    while (d < metric.length) {
      final len = math.min(dash, metric.length - d);
      out.addPath(metric.extractPath(d, d + len), Offset.zero);
      d += dash + gap;
    }
  }
  return out;
}

// ---------- 小部件 ----------

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(icon, size: 21, color: scheme.onSurface),
        ),
      ),
    );
  }
}

class _SegTab extends StatelessWidget {
  const _SegTab({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final fg = active ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Expanded(
      child: Material(
        color: active ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          // 撑满分段槽高度:选中底色才是完整色块,而非缩成文本行高
          child: SizedBox.expand(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  const _ToolBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.enabled = true,
    this.tint,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool enabled;

  /// 非选中态的着色(清空按钮的 error 色)。
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final bg = active ? scheme.primaryContainer : Colors.transparent;
    final fg = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: .35)
        : active
        ? scheme.onPrimaryContainer
        : (tint ?? scheme.onSurfaceVariant);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(13),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 62,
          height: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 21, color: fg),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParamChip extends StatelessWidget {
  const _ParamChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(13),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: active
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: .6),
                  ),
                )
              : null,
          child: Row(
            children: [
              Icon(icon, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                '$label $value',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 扩图尺寸弹窗:宽/高各一行,± 步进 64 或直接输入;确定返回目标尺寸
/// (非法输入回退为打开时的值,等效未修改)。
class _ExpandSizeDialog extends StatefulWidget {
  const _ExpandSizeDialog({
    required this.initW,
    required this.initH,
    required this.minW,
    required this.minH,
  });

  final int initW, initH;
  final int minW, minH; // 原图尺寸 = 下限

  @override
  State<_ExpandSizeDialog> createState() => _ExpandSizeDialogState();
}

class _ExpandSizeDialogState extends State<_ExpandSizeDialog> {
  late final TextEditingController _w = TextEditingController(
    text: '${widget.initW}',
  );
  late final TextEditingController _h = TextEditingController(
    text: '${widget.initH}',
  );

  @override
  void dispose() {
    _w.dispose();
    _h.dispose();
    super.dispose();
  }

  void _step(TextEditingController ctl, int fallback, int minV, int delta) {
    final cur = int.tryParse(ctl.text.trim()) ?? fallback;
    final next = math.max(minV, ((cur + delta) / 64).round() * 64);
    ctl.value = TextEditingValue(
      text: '$next',
      selection: TextSelection.collapsed(offset: '$next'.length),
    );
  }

  Widget _row(String label, TextEditingController ctl, int fallback, int minV) {
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        IconButton.filledTonal(
          onPressed: () => _step(ctl, fallback, minV, -64),
          icon: const Icon(Icons.remove, size: 18),
          visualDensity: VisualDensity.compact,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: ctl,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          onPressed: () => _step(ctl, fallback, minV, 64),
          icon: const Icon(Icons.add, size: 18),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('扩图尺寸'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row('宽', _w, widget.initW, widget.minW),
          const SizedBox(height: 10),
          _row('高', _h, widget.initH, widget.minH),
          const SizedBox(height: 12),
          Text(
            '原图 ${widget.minW}×${widget.minH},增量对称分配到两侧(64 对齐)',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            w: int.tryParse(_w.text.trim()) ?? widget.initW,
            h: int.tryParse(_h.text.trim()) ?? widget.initH,
          )),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 「按住对比」:按住期间隐藏遮罩/裁切框,只看原图。
class _CompareButton extends StatelessWidget {
  const _CompareButton({required this.onChanged});

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Listener(
      onPointerDown: (_) => onChanged(true),
      onPointerUp: (_) => onChanged(false),
      onPointerCancel: (_) => onChanged(false),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: .85),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: .7),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .14),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_outlined, size: 16, color: scheme.onSurface),
            const SizedBox(width: 7),
            Text(
              '按住对比',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
