import 'dart:math';

import 'models.dart';

/// 单张生成成本预估(对齐 web costCalculator):Opus 且 steps≤28 且
/// 像素≤1048576 免费;否则 ceil(5.773e-7 · 像素 · (steps+5))(无 SMEA,
/// 系数 1),最低 2。图生图按强度折算;Vibe 第 5 张起每张 +2、角色参考
/// 每张 +5(两者免费档也照收;CR 仅 4.5 模型实际下发,故按模型计费)。
int estimateCost(GenerateState s, {required bool isOpus}) {
  final p = s.params;
  if (isModalModel(p.model)) return 0; // Anima / Krea 走 Modal 后端,不扣 Anlas
  final pixels = p.width * p.height;
  final free = isOpus && p.steps <= 28 && pixels <= 1048576;
  var baseCost = max(2, (5.773e-7 * pixels * (p.steps + 5)).ceil());
  final i2i = s.img2img;
  if (i2i?.image != null) baseCost = max(2, (baseCost * i2i!.strength).ceil());
  final vibeExtra = max(0, s.enabledVibes - 4) * 2;
  final crExtra = crSupportsModel(p.model) ? s.enabledCharRefs * 5 : 0;
  return (free ? 0 : baseCost) + vibeExtra + crExtra;
}

/// 重绘成本预估:同一公式,但像素按**发送尺寸**算(局部=64 对齐后的
/// 裁切框,整图=原图),再按强度折算(对齐 web:局部重绘点数按小区算,
/// Opus 免费判定同样适用)。vibe/CR 附加费随快照照收。
int estimateInpaintCost(
  GenerateState s, {
  required bool isOpus,
  required int sendW,
  required int sendH,
  required double strength,
}) {
  final p = s.params;
  if (isModalModel(p.model)) return 0; // Anima / Krea 走 Modal 后端,不扣 Anlas
  final pixels = sendW * sendH;
  final free = isOpus && p.steps <= 28 && pixels <= 1048576;
  var baseCost = max(2, (5.773e-7 * pixels * (p.steps + 5)).ceil());
  baseCost = max(2, (baseCost * strength).ceil());
  final vibeExtra = max(0, s.enabledVibes - 4) * 2;
  final crExtra = crSupportsModel(p.model) ? s.enabledCharRefs * 5 : 0;
  return (free ? 0 : baseCost) + vibeExtra + crExtra;
}
