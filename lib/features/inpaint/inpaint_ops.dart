/// 重绘(inpaint)纯图像逻辑:8×8 网格遮罩、mask 导出、裁切/贴回、发送框对齐。
///
/// 对齐 web 桌面端(InpaintOverlay/maskCrop):遮罩最终按 8px 网格量化
/// (有涂抹的格子整格算重绘区,适配 VAE 潜空间),这里索性以网格为存储,
/// 所见即所发;发送框 64 对齐、结果只把 tight 区域贴回原图。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import 'dart:ui' as ui;

/// 像素矩形(整数坐标),用于裁切框/发送框。
typedef IntRect = ({int x, int y, int w, int h});

/// 8×8 网格遮罩位图。cells 一格一字节,非 0 = 重绘区。
class MaskGrid {
  MaskGrid(this.imgW, this.imgH)
    : gw = (imgW / 8).ceil(),
      gh = (imgH / 8).ceil(),
      cells = Uint8List((imgW / 8).ceil() * (imgH / 8).ceil());

  MaskGrid._(this.imgW, this.imgH, this.gw, this.gh, this.cells);

  final int imgW, imgH;
  final int gw, gh;
  final Uint8List cells;

  bool get isEmpty {
    for (final c in cells) {
      if (c != 0) return false;
    }
    return true;
  }

  MaskGrid copy() => MaskGrid._(imgW, imgH, gw, gh, Uint8List.fromList(cells));

  void restore(Uint8List snapshot) => cells.setAll(0, snapshot);

  /// 落盘格式:`[imgW:u32BE][imgH:u32BE][cells…]`。
  ///
  /// 直接存格子而不是光栅化成 PNG —— cells 本来就是每格 1 字节的 0/1,
  /// 一张 1216×832 图才 ~15KB,存 PNG 反而要编解码一遍还更大。
  /// 带上原图尺寸是为了 [decodeInto] 能拒绝尺寸对不上的旧蒙版(扩图/裁切后)。
  Uint8List encode() {
    final out = Uint8List(8 + cells.length);
    ByteData.sublistView(out)
      ..setUint32(0, imgW)
      ..setUint32(4, imgH);
    out.setRange(8, out.length, cells);
    return out;
  }

  /// 把 [encode] 的字节读回本网格;尺寸不符或数据损坏返回 false(调用方保持空白)。
  bool decodeInto(Uint8List data) {
    if (data.length < 8) return false;
    final bd = ByteData.sublistView(data);
    if (bd.getUint32(0) != imgW || bd.getUint32(4) != imgH) return false;
    if (data.length - 8 != cells.length) return false;
    cells.setRange(0, cells.length, data, 8);
    return true;
  }

  void clear() => cells.fillRange(0, cells.length, 0);

  /// 方形笔刷落格(对齐 web 桌面端 drawBrush 方块模式):
  /// 以所在格为中心、round(brush/8) 个格的正方形块,网格锚定。
  void paintDot(double cx, double cy, double brush, {bool erase = false}) {
    final v = erase ? 0 : 1;
    final gridCount = math.max(1, (brush / 8).round());
    final half = gridCount ~/ 2;
    final sx = (cx / 8).floor() - half;
    final sy = (cy / 8).floor() - half;
    final gx1 = math.min(gw, sx + gridCount);
    final gy1 = math.min(gh, sy + gridCount);
    for (var gy = math.max(0, sy); gy < gy1; gy++) {
      for (var gx = math.max(0, sx); gx < gx1; gx++) {
        cells[gy * gw + gx] = v;
      }
    }
  }

  /// 两点间连续落格(步长 4px,对齐 web 方块模式),避免快速滑动断点。
  void paintLine(
    ui.Offset from,
    ui.Offset to,
    double brush, {
    bool erase = false,
  }) {
    final dist = (to - from).distance;
    const step = 4.0;
    final n = (dist / step).ceil();
    for (var i = 0; i <= n; i++) {
      final t = n == 0 ? 0.0 : i / n;
      final p = ui.Offset.lerp(from, to, t)!;
      paintDot(p.dx, p.dy, brush, erase: erase);
    }
  }

  /// 区域内是否有涂抹格子(格中心落在 [r] 内)。局部重绘发送前校验用。
  bool hasCellsIn(IntRect r) {
    final gx0 = math.max(0, r.x ~/ 8);
    final gx1 = math.min(gw - 1, (r.x + r.w) ~/ 8);
    final gy0 = math.max(0, r.y ~/ 8);
    final gy1 = math.min(gh - 1, (r.y + r.h) ~/ 8);
    for (var gy = gy0; gy <= gy1; gy++) {
      for (var gx = gx0; gx <= gx1; gx++) {
        if (cells[gy * gw + gx] != 0) {
          final cx = gx * 8 + 4, cy = gy * 8 + 4;
          if (cx >= r.x && cx < r.x + r.w && cy >= r.y && cy < r.y + r.h) {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// 遮罩区域的**并集轮廓**(图像素坐标):只画邻格为空的那些边,
  /// 相邻两格之间的内部边跳过 —— 出来的是外轮廓,不是一片网格线。
  ///
  /// 重绘完成后遮罩改用轮廓显示:55% 实心紫盖住的恰好就是唯一变了的那块,
  /// 挡着没法看结果;轮廓既不遮像素,又还留着"刚才涂的是哪"。
  ui.Path outlinePath() {
    final p = ui.Path();
    bool on(int gx, int gy) =>
        gx >= 0 && gy >= 0 && gx < gw && gy < gh && cells[gy * gw + gx] != 0;
    for (var gy = 0; gy < gh; gy++) {
      for (var gx = 0; gx < gw; gx++) {
        if (!on(gx, gy)) continue;
        final l = gx * 8.0;
        final t = gy * 8.0;
        final r = l + 8;
        final b = t + 8;
        if (!on(gx, gy - 1)) {
          p.moveTo(l, t);
          p.lineTo(r, t);
        }
        if (!on(gx, gy + 1)) {
          p.moveTo(l, b);
          p.lineTo(r, b);
        }
        if (!on(gx - 1, gy)) {
          p.moveTo(l, t);
          p.lineTo(l, b);
        }
        if (!on(gx + 1, gy)) {
          p.moveTo(r, t);
          p.lineTo(r, b);
        }
      }
    }
    return p;
  }

  /// 遮罩格子的显示矩形集合(图像素坐标,行内连续格子合并)。
  List<ui.Rect> displayRects() {
    final rects = <ui.Rect>[];
    for (var gy = 0; gy < gh; gy++) {
      var runStart = -1;
      for (var gx = 0; gx <= gw; gx++) {
        final on = gx < gw && cells[gy * gw + gx] != 0;
        if (on && runStart < 0) runStart = gx;
        if (!on && runStart >= 0) {
          rects.add(
            ui.Rect.fromLTWH(
              runStart * 8.0,
              gy * 8.0,
              (gx - runStart) * 8.0,
              8.0,
            ),
          );
          runStart = -1;
        }
      }
    }
    return rects;
  }
}

/// 遮罩涂抹区域的紧凑包围盒(对齐 web `calculateCropRect`):
/// bbox + [padding],最小 [minSize],clamp 图内;
/// 面积占比 ≥90% 或无涂抹时返回 null(等效全图,不值得裁)。
IntRect? tightCropRect(MaskGrid g, {int padding = 128, int minSize = 256}) {
  var minGx = g.gw, minGy = g.gh, maxGx = -1, maxGy = -1;
  for (var gy = 0; gy < g.gh; gy++) {
    for (var gx = 0; gx < g.gw; gx++) {
      if (g.cells[gy * g.gw + gx] != 0) {
        if (gx < minGx) minGx = gx;
        if (gx > maxGx) maxGx = gx;
        if (gy < minGy) minGy = gy;
        if (gy > maxGy) maxGy = gy;
      }
    }
  }
  if (maxGx < 0) return null; // 无涂抹

  var x0 = math.max(0, minGx * 8 - padding);
  var y0 = math.max(0, minGy * 8 - padding);
  var x1 = math.min(g.imgW, (maxGx + 1) * 8 + padding);
  var y1 = math.min(g.imgH, (maxGy + 1) * 8 + padding);

  // 最小尺寸:不足则向两侧对称扩(贴边时向另一侧让)
  if (x1 - x0 < minSize) {
    final grow = minSize - (x1 - x0);
    x0 = math.max(0, x0 - grow ~/ 2);
    x1 = math.min(g.imgW, x0 + minSize);
    x0 = math.max(0, x1 - minSize);
  }
  if (y1 - y0 < minSize) {
    final grow = minSize - (y1 - y0);
    y0 = math.max(0, y0 - grow ~/ 2);
    y1 = math.min(g.imgH, y0 + minSize);
    y0 = math.max(0, y1 - minSize);
  }

  final area = (x1 - x0) * (y1 - y0);
  if (area >= g.imgW * g.imgH * 0.9) return null; // 占比过大,等效全图
  return (x: x0, y: y0, w: x1 - x0, h: y1 - y0);
}

/// 发送框:把 tight 区域扩展到**原图的 64px 网格**(左/上边界向下对齐、
/// 右/下边界向上对齐)。x/y 必须落在网格线上——原图遮罩已按 8×8 网格
/// 量化,若裁切原点不对齐,子图内遮罩相对 VAE 网格相位错开,圆刷边缘
/// 会出块状伪影(对齐 web `maskCrop.ts` 的修复版实现)。
/// 原图本身非 64 倍数时无法两全,优先保证发送尺寸合法。
IntRect alignSendRect(IntRect tight, int fullW, int fullH) {
  const grid = 64;
  var x = tight.x ~/ grid * grid;
  var y = tight.y ~/ grid * grid;
  final right = math.min(fullW, ((tight.x + tight.w) / grid).ceil() * grid);
  final bottom = math.min(fullH, ((tight.y + tight.h) / grid).ceil() * grid);

  var w = right - x;
  var h = bottom - y;
  // 夹到原图边后尺寸不再是 64 倍数(非对齐图)→ 回退 floor(原图/64)*64
  if (w > fullW || w % grid != 0) w = math.max(grid, fullW ~/ grid * grid);
  if (h > fullH || h % grid != 0) h = math.max(grid, fullH ~/ grid * grid);
  if (x + w > fullW) x = math.max(0, fullW - w);
  if (y + h > fullH) y = math.max(0, fullH - h);

  // 尽量把 tight 的右/下边缘包含进发送区
  final tr = tight.x + tight.w;
  final tb = tight.y + tight.h;
  if (tr > x + w) x = math.min(fullW - w, tr - w);
  if (tb > y + h) y = math.min(fullH - h, tb - h);
  return (x: x, y: y, w: w, h: h);
}

/// 网格导出黑白 mask PNG(白=重绘区)。[region] 非空时输出该区域
/// (坐标相对原图,尺寸=region;框外格子自然丢弃),空时输出整图尺寸。
Future<Uint8List> maskToPng(MaskGrid g, {IntRect? region}) async {
  final w = region?.w ?? g.imgW;
  final h = region?.h ?? g.imgH;
  final ox = region?.x ?? 0;
  final oy = region?.y ?? 0;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0));
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0),
    ui.Paint()..color = const ui.Color(0xFF000000),
  );
  final white = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
  for (final r in g.displayRects()) {
    final shifted = r.shift(ui.Offset(-ox * 1.0, -oy * 1.0));
    if (shifted.right <= 0 ||
        shifted.bottom <= 0 ||
        shifted.left >= w ||
        shifted.top >= h) {
      continue;
    }
    canvas.drawRect(shifted, white);
  }
  final picture = recorder.endRecording();
  final img = await picture.toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 从 PNG 裁出子区(像素精确),输出 PNG。
Future<Uint8List> cropPng(Uint8List src, IntRect rect) async {
  final codec = await ui.instantiateImageCodec(src);
  final frame = await codec.getNextFrame();
  final img = frame.image;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(
    recorder,
    ui.Rect.fromLTWH(0, 0, rect.w * 1.0, rect.h * 1.0),
  );
  canvas.drawImageRect(
    img,
    ui.Rect.fromLTWH(rect.x * 1.0, rect.y * 1.0, rect.w * 1.0, rect.h * 1.0),
    ui.Rect.fromLTWH(0, 0, rect.w * 1.0, rect.h * 1.0),
    ui.Paint(),
  );
  final picture = recorder.endRecording();
  final out = await picture.toImage(rect.w, rect.h);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  out.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 扩图发送底图(对齐 web 桌面端 handleGenerate 扩图分支):
/// 白底 (imgW+padL+padR)×(imgH+padT+padB) 画布,原图贴在 (padL, padT)。
Future<Uint8List> buildExpandImage(
  Uint8List src, {
  required int padL,
  required int padT,
  required int padR,
  required int padB,
}) async {
  final codec = await ui.instantiateImageCodec(src);
  final img = (await codec.getNextFrame()).image;
  final w = img.width + padL + padR;
  final h = img.height + padT + padB;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0));
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  canvas.drawImage(img, ui.Offset(padL * 1.0, padT * 1.0), ui.Paint());
  final picture = recorder.endRecording();
  final out = await picture.toImage(w, h);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  out.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 扩图 mask:全白(新增区=重绘),原图覆盖区黑(保留)。
/// 原图 64 对齐 + padding 恒 64 倍数,边界天然落 8×8 网格,无需再量化。
Future<Uint8List> buildExpandMask({
  required int imgW,
  required int imgH,
  required int padL,
  required int padT,
  required int padR,
  required int padB,
}) async {
  final w = imgW + padL + padR;
  final h = imgH + padT + padB;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0));
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(padL * 1.0, padT * 1.0, imgW * 1.0, imgH * 1.0),
    ui.Paint()..color = const ui.Color(0xFF000000),
  );
  final picture = recorder.endRecording();
  final out = await picture.toImage(w, h);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  out.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 局部重绘结果贴回:以原图为底,把 patch(发送框尺寸)中对应
/// tight 区域的部分贴到原图 tight 位置(对齐 web:只覆盖紧凑区,
/// 其余保持原像素,减少 VAE 往返色差影响范围)。输出整图 PNG。
Future<Uint8List> pasteBack({
  required Uint8List original,
  required Uint8List patch,
  required IntRect send,
  required IntRect tight,
}) async {
  final baseCodec = await ui.instantiateImageCodec(original);
  final base = (await baseCodec.getNextFrame()).image;
  final patchCodec = await ui.instantiateImageCodec(patch);
  final patchImg = (await patchCodec.getNextFrame()).image;

  final w = base.width, h = base.height;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0));
  canvas.drawImage(base, ui.Offset.zero, ui.Paint());
  canvas.drawImageRect(
    patchImg,
    ui.Rect.fromLTWH(
      (tight.x - send.x) * 1.0,
      (tight.y - send.y) * 1.0,
      tight.w * 1.0,
      tight.h * 1.0,
    ),
    ui.Rect.fromLTWH(
      tight.x * 1.0,
      tight.y * 1.0,
      tight.w * 1.0,
      tight.h * 1.0,
    ),
    ui.Paint(),
  );
  final picture = recorder.endRecording();
  final out = await picture.toImage(w, h);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  base.dispose();
  patchImg.dispose();
  out.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 重绘编辑器的工具偏好:笔刷粗细、重绘强度、偏位套杆。
///
/// 只记**手感类**的三项。画笔/橡皮、局部、扩图这些是「这一张要怎么处理」,
/// 每次进来都该从干净状态起步,记住反而碍事。
class InpaintPrefs {
  const InpaintPrefs({
    this.brush = 50, // 笔刷直径(图像素),对齐 web 默认
    this.strength = 0.7,
    this.assist = false,
  });

  final double brush;
  final double strength;

  /// 偏位套杆:光标偏于触点上方,手指不挡涂抹点。用不用是个人习惯。
  final bool assist;

  Map<String, dynamic> toJson() => {
    'brush': brush,
    'strength': strength,
    'assist': assist,
  };

  factory InpaintPrefs.fromJson(Map<String, dynamic> j) => InpaintPrefs(
    brush: ((j['brush'] as num?)?.toDouble() ?? 50).clamp(4, 400),
    strength: ((j['strength'] as num?)?.toDouble() ?? 0.7).clamp(0.01, 1.0),
    assist: j['assist'] == true,
  );
}

const _inpaintPrefsKey = 'inpaint_prefs';

/// 同步读:PrefsStore 的内存表在 AppStores.open 时已经装满,所以这里没有
/// 「首帧还没读出来」那一档 —— 面板一开就是上次的手感,不会先跳回默认值。
final inpaintPrefsProvider =
    NotifierProvider<InpaintPrefsNotifier, InpaintPrefs>(
      InpaintPrefsNotifier.new,
    );

class InpaintPrefsNotifier extends Notifier<InpaintPrefs> {
  @override
  InpaintPrefs build() {
    try {
      final raw = ref.read(prefsStoreProvider).get(_inpaintPrefsKey);
      if (raw == null || raw.isEmpty) return const InpaintPrefs();
      return InpaintPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const InpaintPrefs(); // 损坏/无 AppStores(测试)按默认
    }
  }

  /// 关面板时存一次。**不在滑杆每一跳都写** —— 那是每帧一次整份 JSON 落盘。
  Future<void> save(InpaintPrefs p) async {
    state = p;
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _inpaintPrefsKey, value: jsonEncode(p.toJson()));
    } catch (_) {} // 写失败只影响下次恢复
  }
}
