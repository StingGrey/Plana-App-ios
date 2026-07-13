import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/nai_client.dart';
import 'vibe_cache.dart';

/// 统一 Vibe 编码服务:内容寻址缓存优先,miss 时按当前授权模式
/// (直连 NAI / bot 后端)现场编码(扣 2 Anlas)并回填缓存。
/// 生成链路与库页「预编码」共用同一入口,避免多处实现漂移。
final vibeEncoderProvider = Provider<VibeEncoder>(VibeEncoder.new);

class VibeEncoder {
  VibeEncoder(this._ref);

  final Ref _ref;

  /// 只查缓存,不发起编码。
  Future<String?> cached({
    required String imageHash,
    required String model,
    required double infoExtracted,
  }) async {
    final cache = await _ref.read(vibeCacheProvider.future);
    return cache.get(imageHash, model, infoExtracted);
  }

  /// 缓存优先编码。未授权抛 [StateError](调用方兜 UI 提示)。
  Future<String> encode({
    required Uint8List image,
    required String imageHash,
    required String model,
    required double infoExtracted,
  }) async {
    final cache = await _ref.read(vibeCacheProvider.future);
    final hit = await cache.get(imageHash, model, infoExtracted);
    if (hit != null) return hit;

    final String enc;
    if (_ref.read(authModeProvider).value == AuthMode.bot) {
      final session = await _ref.read(botSessionProvider.future);
      if (session == null) throw StateError('Bot 未授权,无法编码');
      enc = await _ref.read(backendClientProvider).encodeVibe(
            sessionId: session.sessionId,
            imageBase64: base64Encode(image),
            informationExtracted: infoExtracted,
            model: model,
          );
    } else {
      final token = await _ref.read(tokenProvider.future);
      if (token == null || token.isEmpty) throw StateError('未设置令牌,无法编码');
      enc = await _ref.read(naiClientProvider).encodeVibe(
            token: token,
            imageBase64: base64Encode(image),
            infoExtracted: infoExtracted,
            model: model,
          );
    }
    await cache.put(imageHash, model, infoExtracted, enc);
    return enc;
  }
}
