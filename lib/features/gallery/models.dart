/// 图库数据模型。当前里程碑仅承载 UI 占位,
/// 后续接 NAI 生成链路时补 bytes / 本地缓存路径与生成参数快照。
library;

import 'dart:typed_data';
import 'dart:ui' show Color;

import '../generate/models.dart' show GenerateState;

/// 结果图的处理标记 —— 决定缩略图角标与画布顶部标签。
enum ResultBadge { none, upscaled, inpaint }

extension ResultBadgeX on ResultBadge {
  /// 角标短文案;none 无角标。
  String? get label => switch (this) {
        ResultBadge.upscaled => '4x',
        ResultBadge.inpaint => '重绘',
        ResultBadge.none => null,
      };

  /// 角标底色 —— 语义状态色(超分绿 / 重绘紫),与全局金色主题区隔。
  Color get color => switch (this) {
        ResultBadge.upscaled => const Color(0xFF2E7D32),
        ResultBadge.inpaint => const Color(0xFF7E57C2),
        ResultBadge.none => const Color(0x00000000),
      };
}

/// 一张生成结果。占位阶段无像素数据,画布与缩略图用斜纹占位呈现,
/// 尺寸/种子/角标则真实驱动界面。
class ResultImage {
  const ResultImage({
    required this.id,
    required this.width,
    required this.height,
    required this.seed,
    this.badge = ResultBadge.none,
    this.bytes,
    this.input,
  });

  final String id;
  final int width;
  final int height;
  final int seed;
  final ResultBadge badge;

  /// 真实 PNG 字节;占位历史为 null(用斜纹呈现)。
  final Uint8List? bytes;

  /// 生成时的输入快照(prompt/角色/参考/参数);供「重新生成」按本图参数复现。
  final GenerateState? input;

  double get aspect => width / height;
}
