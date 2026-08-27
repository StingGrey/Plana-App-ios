import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';

/// 公共 Vibe 库列表(`GET /api/vibes/list`)。依赖 bot 会话:
/// 未授权时抛 [StateError]('need-bot'),UI 层据此显示授权提示。
/// 缩略图端点公开,列表项 thumbnailUrl 直接给 RemoteImage(带磁盘缓存)。
final publicVibesProvider = FutureProvider<List<PublicVibeMeta>>((ref) async {
  final session = await ref.watch(botSessionProvider.future);
  if (session == null) throw StateError('need-bot');
  return ref.read(backendClientProvider).listPublicVibes(session.sessionId);
});
