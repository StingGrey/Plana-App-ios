import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../generate/widgets/common.dart' show StripeThumb;
import '../gallery_state.dart' show galleryImageProvider, galleryThumbProvider;
import '../models.dart';

/// 缩略图:内存有字节直接用;没有(重启水合/RAM 减负)按 id 懒读盘上。
/// 默认读取方形缩略图;[useOriginal] 用于必须展示完整构图的平板历史栏。
class ResultThumb extends ConsumerWidget {
  const ResultThumb({
    super.key,
    required this.result,
    required this.width,
    required this.height,
    this.radius = 10,
    this.fit = BoxFit.cover,
    this.useOriginal = false,
  });

  final ResultImage result;
  final double width;
  final double height;
  final double radius;
  final BoxFit fit;
  final bool useOriginal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes =
        result.bytes ??
        (useOriginal
            ? ref.watch(galleryImageProvider(result.id)).value
            : ref.watch(galleryThumbProvider(result.id)).value);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.memory(
          bytes,
          width: width,
          height: height,
          fit: fit,
          cacheWidth: useOriginal
              ? (width * MediaQuery.devicePixelRatioOf(context)).round()
              : null,
          gaplessPlayback: true,
        ),
      );
    }
    return StripeThumb(width: width, height: height, radius: radius);
  }
}
