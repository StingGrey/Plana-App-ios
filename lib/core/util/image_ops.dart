import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 解码图片像素尺寸 (宽, 高)。
Future<(int, int)> decodeImageSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final img = frame.image;
  final size = (img.width, img.height);
  img.dispose();
  return size;
}

/// img2img 目标分辨率(与 web `setImg2imgWithAutoRes` 一致):
/// 各边取整到 64 的倍数、最小 64;总像素超 1024×3072 则等比缩回。
({int w, int h}) img2imgResolution(int rawW, int rawH) {
  int w = math.max(64, (rawW / 64).round() * 64);
  int h = math.max(64, (rawH / 64).round() * 64);
  const maxPixels = 1024 * 3072; // 3,145,728
  if (w * h > maxPixels) {
    final scale = math.sqrt(maxPixels / (w * h));
    w = math.max(64, ((w * scale) / 64).floor() * 64);
    h = math.max(64, ((h * scale) / 64).floor() * 64);
  }
  return (w: w, h: h);
}

/// 把图 cover(填满,居中裁切)到目标尺寸、黑底兜底,输出 PNG 字节。
/// 复刻 web `processImg2ImgImage` 的 canvas.drawImage 行为。
Future<Uint8List> coverResizePng(
  Uint8List src,
  int targetW,
  int targetH,
) async {
  final codec = await ui.instantiateImageCodec(src);
  final frame = await codec.getNextFrame();
  final img = frame.image;

  final iw = img.width.toDouble();
  final ih = img.height.toDouble();
  final tw = targetW.toDouble();
  final th = targetH.toDouble();
  final scale = math.max(tw / iw, th / ih); // cover
  final sw = iw * scale;
  final sh = ih * scale;
  final dx = (tw - sw) / 2;
  final dy = (th - sh) / 2;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, tw, th));
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, tw, th),
    ui.Paint()..color = const ui.Color(0xFF000000),
  );
  canvas.drawImageRect(
    img,
    ui.Rect.fromLTWH(0, 0, iw, ih),
    ui.Rect.fromLTWH(dx, dy, sw, sh),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final picture = recorder.endRecording();
  final out = await picture.toImage(targetW, targetH);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);

  img.dispose();
  out.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 角色参考(CR)预处理,复刻 web `processCRImage`:按宽高比选目标画布,
/// contain(整图可见、按比例缩放)+ 黑边居中填充,输出 PNG。
/// 方形(0.8≤AR≤1.25)→1472²;横图→1536×1024;竖图→1024×1536。
Future<Uint8List> crResizePng(Uint8List src) async {
  final codec = await ui.instantiateImageCodec(src);
  final frame = await codec.getNextFrame();
  final img = frame.image;

  final iw = img.width.toDouble();
  final ih = img.height.toDouble();
  final ar = iw / ih;

  int cw, ch;
  if (ar >= 0.8 && ar <= 1.25) {
    cw = 1472;
    ch = 1472;
  } else if (iw > ih) {
    cw = 1536;
    ch = 1024;
  } else {
    cw = 1024;
    ch = 1536;
  }

  final twd = cw.toDouble();
  final thd = ch.toDouble();
  final scale = math.min(twd / iw, thd / ih); // contain
  final sw = iw * scale;
  final sh = ih * scale;
  final dx = (twd - sw) / 2;
  final dy = (thd - sh) / 2;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, twd, thd));
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, twd, thd),
    ui.Paint()..color = const ui.Color(0xFF000000),
  );
  canvas.drawImageRect(
    img,
    ui.Rect.fromLTWH(0, 0, iw, ih),
    ui.Rect.fromLTWH(dx, dy, sw, sh),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final picture = recorder.endRecording();
  final out = await picture.toImage(cw, ch);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);

  img.dispose();
  out.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
