/// 图片网格的响应式列数。手机保留双列,平板按约 180dp 一列扩到最多六列。
int responsiveImageColumns(
  double width, {
  double targetTileWidth = 180,
  int min = 2,
  int max = 6,
}) {
  if (!width.isFinite || width <= 0) return min;
  return (width / targetTileWidth).floor().clamp(min, max);
}
