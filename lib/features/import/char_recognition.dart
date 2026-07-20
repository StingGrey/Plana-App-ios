import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/prompt_tokens.dart';
import '../editor/data/artist_oc_library.dart';
import '../editor/data/role_library.dart';

/// 角色识别(元数据详情):角色词库按分词命中 + OC 库按标签串 LCS 命中。
/// 词库不可用(离线且无缓存 / 未授权)时得空列表,区块整体隐藏。
class RecognizedChar {
  const RecognizedChar({
    required this.zh,
    required this.en,
    this.origin = '',
    this.isOc = false,
  });

  final String zh;
  final String en;
  final String origin;
  final bool isOc;
}

final charRecognitionProvider = FutureProvider.autoDispose
    .family<List<RecognizedChar>, String>((ref, fullPrompt) async {
  if (fullPrompt.trim().isEmpty) return const [];
  final out = <RecognizedChar>[];
  try {
    final roles = await ref
        .watch(roleLibraryProvider)
        .matchInPrompt(tokenizeSet(fullPrompt));
    out.addAll([
      for (final r in roles)
        RecognizedChar(zh: r.zh, en: r.en, origin: r.origin),
    ]);
  } catch (_) {}
  try {
    final ocs = await ref
        .watch(artistOcLibraryProvider)
        .matchOcsInPrompt(tokenizeSeq(fullPrompt));
    out.addAll([
      for (final o in ocs) RecognizedChar(zh: o.zh, en: o.en, isOc: true),
    ]);
  } catch (_) {}
  return out.take(5).toList();
});

/// 详情页「角色识别」区块:无命中时零占位。
class CharRecognitionSection extends ConsumerWidget {
  const CharRecognitionSection({super.key, required this.fullPrompt});

  final String fullPrompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final matches =
        ref.watch(charRecognitionProvider(fullPrompt)).value ?? const [];
    if (matches.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '角色识别'.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final m in matches) _chip(context, m)],
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, RecognizedChar m) {
    final scheme = context.scheme;
    final fg = m.isOc ? scheme.tertiary : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.isOc) ...[
            Text(
              'OC',
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            m.zh,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              m.origin.isNotEmpty ? '${m.en} · ${m.origin}' : m.en,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: fg.withValues(alpha: .65)),
            ),
          ),
        ],
      ),
    );
  }
}
