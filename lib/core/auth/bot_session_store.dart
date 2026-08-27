import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// Bot 授权得到的后端会话。`sessionId` 本体即后端 `Authorization: Bearer` 令牌。
/// 7 天滑动过期,由 `/api/bot/auth/validate` 回传 `expiresAtMs` 同步。
class BotSession {
  const BotSession({required this.sessionId, this.botUserId, this.expiresAtMs});

  final String sessionId;
  final String? botUserId;
  final int? expiresAtMs;

  bool get expired =>
      expiresAtMs != null &&
      DateTime.now().millisecondsSinceEpoch >= expiresAtMs!;

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'botUserId': botUserId,
    'expiresAtMs': expiresAtMs,
  };

  factory BotSession.fromJson(Map<String, dynamic> j) => BotSession(
    sessionId: j['sessionId'] as String,
    botUserId: j['botUserId'] as String?,
    expiresAtMs: (j['expiresAtMs'] as num?)?.toInt(),
  );
}

const _botSessionKey = 'bot_session';

final botSessionProvider =
    AsyncNotifierProvider<BotSessionNotifier, BotSession?>(
      BotSessionNotifier.new,
    );

class BotSessionNotifier extends AsyncNotifier<BotSession?> {
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  @override
  Future<BotSession?> build() async {
    try {
      final raw = await _storage.read(key: _botSessionKey);
      if (raw == null || raw.isEmpty) return null;
      return BotSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(BotSession session) async {
    try {
      await _storage.write(
        key: _botSessionKey,
        value: jsonEncode(session.toJson()),
      );
      state = AsyncData(session);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// validate 后同步过期时间/归属。
  Future<void> touch({int? expiresAtMs, String? botUserId}) async {
    final cur = state.value;
    if (cur == null) return;
    await save(
      BotSession(
        sessionId: cur.sessionId,
        botUserId: botUserId ?? cur.botUserId,
        expiresAtMs: expiresAtMs ?? cur.expiresAtMs,
      ),
    );
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _botSessionKey);
    } catch (_) {}
    state = const AsyncData(null);
  }
}
