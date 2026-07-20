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

/// 一张生成结果。bytes/input 只是**内存缓存**——重启水合或 RAM 减负后
/// 为 null,像素与快照按 id 从 GalleryStore 懒读;hasInput 记录盘上
/// 是否有参数快照(操作门禁用,与 input 是否驻留内存无关)。
class ResultImage {
  const ResultImage({
    required this.id,
    required this.width,
    required this.height,
    required this.seed,
    this.badge = ResultBadge.none,
    this.bytes,
    this.input,
    bool? hasInput,
  }) : hasInput = hasInput ?? input != null;

  final String id;
  final int width;
  final int height;
  final int seed;
  final ResultBadge badge;

  /// PNG 字节(内存缓存);null 时按需从盘读,读不到才是真无像素。
  final Uint8List? bytes;

  /// 生成时的输入快照(prompt/角色/参考/参数);供「重新生成」按本图参数复现。
  final GenerateState? input;

  /// 本图有参数快照可用(内存或盘上)。
  final bool hasInput;

  double get aspect => width / height;

  /// 卸掉内存缓存的副本(字节/快照盘上都有,再用时懒读)。
  ResultImage stripped() => (bytes == null && input == null)
      ? this
      : ResultImage(
          id: id,
          width: width,
          height: height,
          seed: seed,
          badge: badge,
          hasInput: hasInput,
        );
}
