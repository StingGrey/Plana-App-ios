import 'package:flutter/material.dart';

import '../models.dart';

/// 缩略图角标(4x / 重绘)—— 语义状态色小药丸,胶片条与网格共用。
class ResultBadgeChip extends StatelessWidget {
  const ResultBadgeChip({super.key, required this.badge});

  final ResultBadge badge;

  @override
  Widget build(BuildContext context) {
    final label = badge.label;
    if (label == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: badge.color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 缩略图右上角「已存进相册」小圆标,胶片条与网格共用。底色与网格时刻角标同一层黑纱。
class SavedMark extends StatelessWidget {
  const SavedMark({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: .45),
      ),
      child: Icon(
        Icons.download_done,
        size: size * .7,
        color: Colors.white.withValues(alpha: .92),
      ),
    );
  }
}
