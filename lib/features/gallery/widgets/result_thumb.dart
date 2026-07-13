import 'package:flutter/material.dart';

import '../../generate/widgets/common.dart' show StripeThumb;
import '../models.dart';

/// 缩略图:有真实字节 → Image.memory(cover);否则斜纹占位。
/// 胶片条与网格共用,尺寸由外部给定。
class ResultThumb extends StatelessWidget {
  const ResultThumb({
    super.key,
    required this.result,
    required this.width,
    required this.height,
    this.radius = 10,
  });

  final ResultImage result;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (result.bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.memory(
          result.bytes!,
          width: width,
          height: height,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    return StripeThumb(width: width, height: height, radius: radius);
  }
}
