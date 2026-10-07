import 'dart:math';

/// 分辨率规则,数值对齐 web 桌面端 `LeftSidebar.tsx`:
/// 64 对齐、最小 64、像素预算 3,145,728、免费阈值 1,048,576。
/// 纯 int/double 运算,不依赖任何 UI 或 model,供分辨率选择与自定义编辑复用。
const int kResSnapStep = 64;
const int kMinDim = 64;

/// 单边步进上限:web input 无 max,靠像素预算兜底;移动端步进器给个合理封顶。
/// 3072 = 与 1024 搭配即达像素预算的最大单边(web 演示的最大单边)。
const int kMaxDim = 3072;

/// 像素预算上限 1024×3072 = 3,145,728;超过即「超限」,生成端会拒。
const int kMaxTotalPixels = 1024 * 3072;

/// 免费阈值 1024×1024 = 1,048,576;像素 ≤ 此值为免费档(Opus·≤28 步单张免费)。
const int kFreePixelThreshold = 1024 * 1024;

/// 归一到 64 的倍数,且不小于 64。
int snapDim(int v) {
  final s = (v / kResSnapStep).round() * kResSnapStep;
  return s < kMinDim ? kMinDim : s;
}

/// 尺寸档:免费 / 收费 / 超限(与 web classifyPixelStatus 一致)。
enum PixelTier { free, paid, over }

PixelTier classifyPixels(int width, int height) {
  final pixels = width * height;
  if (pixels > kMaxTotalPixels) return PixelTier.over;
  if (pixels > kFreePixelThreshold) return PixelTier.paid;
  return PixelTier.free;
}

/// 64 对齐后若超像素预算,按 √ 比例缩回并向下取整到 64(与 web clampToMaxPixels 一致)。
({int w, int h}) clampToMaxPixels(int width, int height) =>
    _scaleUnder(width, height, kMaxTotalPixels);

/// 缩到免费档(≤ 1,048,576),保持比例,向下取整到 64。
({int w, int h}) scaleToFree(int width, int height) =>
    _scaleUnder(width, height, kFreePixelThreshold);

/// 先 64 对齐;若像素超过 budget,按 √(budget/像素) 缩放并向下取整到 64。
({int w, int h}) _scaleUnder(int width, int height, int budget) {
  var w = snapDim(width);
  var h = snapDim(height);
  final pixels = w * h;
  if (pixels > budget) {
    final scale = sqrt(budget / pixels);
    w = max(kMinDim, ((w * scale) / kResSnapStep).floor() * kResSnapStep);
    h = max(kMinDim, ((h * scale) / kResSnapStep).floor() * kResSnapStep);
  }
  return (w: w, h: h);
}

/// 已知一边 [a],另一边在乘积不超 [budget] 时能取的最大 64 倍数(不钳单边范围)。
int _fitSide(int a, int budget) => budget ~/ a ~/ kResSnapStep * kResSnapStep;

/// (w, h) 是否贴在等像素线 w×h=[budget] 内侧:至少一边已是对边允许的最大格,
/// 再加 64 就越线。线出了画布的那段(对边要超 [kMaxDim])自然不算。
bool isOnPixelLine(int w, int h, int budget) =>
    _fitSide(w, budget) == h || _fitSide(h, budget) == w;

/// 点 (x, y)(真实像素,未对齐)到等像素线 w×h=[budget] 的法向距离。
/// 一阶近似 |xy − budget| / |∇(xy)|:吸附只看贴线附近,这个精度够;原点处无穷远。
double distanceToPixelLine(double x, double y, int budget) {
  final g = sqrt(x * x + y * y);
  return g == 0 ? double.infinity : (x * y - budget).abs() / g;
}

/// 把点 (x, y) 吸到等像素线 w×h=[budget] 上:先沿法向投影到曲线,长边取最近的
/// 64 倍数,短边由长边反推 —— 落点紧贴线内侧,档位不会越线。
///
/// 长边定位、短边反推:曲线沿长边方向最平,手指顺着线滑时长边跟手、短边贴线;
/// 反过来拿短边定位,短边挪一格长边就要跳好几格。
({int w, int h}) snapToPixelLine(double x, double y, int budget) {
  final g2 = x * x + y * y;
  final f = g2 == 0 ? 0.0 : (x * y - budget) / g2;
  final px = x - f * y;
  final py = y - f * x;
  int side(double v) => snapDim(v.round()).clamp(kMinDim, kMaxDim);
  int fit(int a) => _fitSide(a, budget).clamp(kMinDim, kMaxDim);
  if (px >= py) {
    final w = side(px);
    return (w: w, h: fit(w));
  }
  final h = side(py);
  return (w: fit(h), h: h);
}

/// 百万像素读数,如 1.05。
double megapixels(int width, int height) => width * height / 1000000;

/// 最简整数比;分子或分母 > 99 时退化为 `x.xx:1` / `1:x.xx`(与 web formatAspectRatio 一致)。
String formatAspectRatio(int width, int height) {
  if (width <= 0 || height <= 0) return '—';
  final g = _gcd(width, height);
  final rw = width ~/ g;
  final rh = height ~/ g;
  if (rw > 99 || rh > 99) {
    final ratio = width / height;
    return ratio >= 1
        ? '${ratio.toStringAsFixed(2)}:1'
        : '1:${(1 / ratio).toStringAsFixed(2)}';
  }
  return '$rw:$rh';
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
