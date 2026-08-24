import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import 'artist_models.dart';
import 'tag_models.dart';

/// 公共库列表(角色=OC、画风=画师串),映射为统一 [TagEntry] 供页面渲染。
/// 依赖 bot 会话:未授权抛 [StateError]('need-bot'),UI 据此显示授权提示
/// (范式同 publicVibesProvider)。场景/其他无公共库。
final publicTagsProvider = FutureProvider.family<List<TagEntry>, TagCategory>((
  ref,
  cat,
) async {
  final session = await ref.watch(botSessionProvider.future);
  if (session == null) throw StateError('need-bot');
  final client = ref.read(backendClientProvider);

  switch (cat) {
    case TagCategory.character:
      final ocs = await client.listPublicOcs(session.sessionId);
      return [
        for (final o in ocs)
          TagEntry(
            id: 'pub_${o.enName}',
            category: TagCategory.character,
            name: o.displayName,
            positive: o.tagGroup,
            negative: o.negativePrompt,
            aliases: o.aliases,
            publicId: o.enName,
            previews: [if (o.previewUrl != null) o.previewUrl!],
            createdAt: o.createdAt * 1000,
            // 归属以服务端 owner_id 为准,存量数据回退 created_by(对齐 web)
            createdBy: o.ownerId ?? o.createdBy,
          ),
      ];
    case TagCategory.artist:
      final artists = await client.listPublicArtists(session.sessionId);
      return [
        for (final a in artists)
          TagEntry(
            id: 'pub_${a.id}',
            category: TagCategory.artist,
            name: a.name,
            positive: a.artistString,
            negative: a.negative,
            models: normalizeArtistModels(a.models),
            publicId: a.id,
            previews: [if (a.previewUrl != null) a.previewUrl!],
            createdAt: a.createdTime * 1000,
            createdBy: a.ownerId ?? a.addedBy,
          ),
      ];
    case TagCategory.scene || TagCategory.other:
      return const [];
  }
});
