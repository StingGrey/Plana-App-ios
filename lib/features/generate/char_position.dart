library;

/// 角色定位:`position` 字段的两种格式统一解析(对齐 web `utils/characterPosition.ts`)。
///   · 网格 id   'A1'..'E5'   —— V4/V4.5(列 A-E × 行 1-5)
///   · 自由坐标  '0.42,0.67'  —— NAI Diffusion V5 自由定位(x,y 均 0~1)
///
/// V5 官方 "No more tiny grids":可在画布任意连续坐标放角色,且单图最多 32 个 ——
/// 25 个格子根本摆不下。两种格式在发送层由 [resolveCharacterCenter] 统一解析,
/// 空 / 非法 = AUTO(交给发送层按序自动排布)。

final _gridRe = RegExp(r'^[A-E][1-5]$');
final _freeRe = RegExp(r'^\s*(\d*\.?\d+)\s*,\s*(\d*\.?\d+)\s*$');

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// 网格 id → 格心归一化坐标;非网格 id 返回 null。
({double x, double y})? _gridCenter(String pos) {
  if (!_gridRe.hasMatch(pos)) return null;
  final col = 'ABCDE'.indexOf(pos[0]);
  final row = int.parse(pos[1]);
  return (
    x: double.parse(((col + 0.5) / 5).toStringAsFixed(4)),
    y: double.parse(((row - 0.5) / 5).toStringAsFixed(4)),
  );
}

/// `position` → 归一化中心坐标 {x,y}。网格 id / 自由坐标统一入口;空 / 非法 → null。
({double x, double y})? resolveCharacterCenter(String? pos) {
  if (pos == null || pos.isEmpty) return null;
  final g = _gridCenter(pos);
  if (g != null) return g;
  final m = _freeRe.firstMatch(pos);
  if (m != null) {
    return (
      x: _clamp01(double.parse(m.group(1)!)),
      y: _clamp01(double.parse(m.group(2)!)),
    );
  }
  return null;
}

/// 0~1 坐标 → 自由坐标串(写进 `position`)。
String formatFreeformPosition(double x, double y) =>
    '${_clamp01(x).toStringAsFixed(4)},${_clamp01(y).toStringAsFixed(4)}';

/// `position` 是否为自由坐标串(而非网格 id / AUTO)。
bool isFreeformPosition(String? pos) => pos != null && _freeRe.hasMatch(pos);

/// 位置徽章文案:AUTO / 网格 id / 自由坐标百分比(如 '42,67%')。
String positionChipLabel(String? pos) {
  if (pos == null || pos.isEmpty) return 'AUTO';
  if (_gridRe.hasMatch(pos)) return pos;
  final m = _freeRe.firstMatch(pos);
  if (m != null) {
    final x = (_clamp01(double.parse(m.group(1)!)) * 100).round();
    final y = (_clamp01(double.parse(m.group(2)!)) * 100).round();
    return '$x,$y%';
  }
  return 'AUTO';
}

/// 两组宽高的横竖比是否一致(判断能否拿主页现有图当角色定位画布)。
bool aspectRatiosMatch(int w1, int h1, int w2, int h2) =>
    w1 > 0 && h1 > 0 && w2 > 0 && h2 > 0 && (w1 / h1 - w2 / h2).abs() < 0.01;

/// 元数据 center(0~1)→ `position`:恰好落 5×5 格心 → 网格 id(V4/V4.5 干净往返);
/// 否则保留精确自由坐标串(V5 自由坐标不吸附丢位置);无坐标 → null=AUTO。
String? positionOfCenter(double? x, double? y) {
  if (x == null || y == null) return null;
  final col = (x * 5 - 0.5).round().clamp(0, 4);
  final row = (y * 5 + 0.5).round().clamp(1, 5);
  final grid = '${'ABCDE'[col]}$row';
  final gc = _gridCenter(grid)!;
  if ((gc.x - x).abs() < 1e-3 && (gc.y - y).abs() < 1e-3) return grid;
  return formatFreeformPosition(x, y);
}
