import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/nai_client.dart';
import '../../core/store/app_stores.dart';

/// NAI 官方超分(远程 4×)。按当前授权模式分发:
///  - bot:走后端 `/api/upscale`(Bearer 会话)。
///  - 直连:app 直打 `api.novelai.net/ai/upscale`(Bearer 用户 token),解 zip。
///
/// 输入原图 PNG + 尺寸(须为 NAI 支持的固定分辨率,调用方先校验);返回 (超分 PNG, 4× 宽高)。
/// NAI 是远程一次性调用,无逐步进度 —— 只经 [onStage] 报阶段文案。
Future<({Uint8List png, int width, int height})> upscaleNai(
  WidgetRef ref,
  Uint8List srcPng, {
  required int width,
  required int height,
  void Function(String stage)? onStage,
}) async {
  onStage?.call('编码图片…');
  final b64 = base64Encode(srcPng);
  final mode = ref.read(authModeProvider).value;

  Uint8List out;
  if (mode == AuthMode.bot) {
    final session = await ref.read(botSessionProvider.future);
    if (session == null) throw Exception('未登录(bot 会话缺失)');
    onStage?.call('提交后端…');
    final r = await ref
        .read(backendClientProvider)
        .upscale(
          sessionId: session.sessionId,
          imageBase64: b64,
          width: width,
          height: height,
        );
    if (!r.success || r.imageBase64 == null || r.imageBase64!.isEmpty) {
      throw Exception(r.message.isNotEmpty ? r.message : 'NAI 超分失败');
    }
    onStage?.call('接收结果…');
    out = base64Decode(r.imageBase64!);
  } else {
    final token = await ref.read(tokenProvider.future);
    if (token == null || token.isEmpty) throw Exception('未配置 NAI Token');
    onStage?.call('上传 NAI…');
    out = await ref
        .read(naiClientProvider)
        .upscale(token: token, imageBase64: b64, width: width, height: height);
    onStage?.call('接收结果…');
    // 本机记账:NAI 4× 超分固定 7 点(用户实测确认;bot 模式由服务端记)
    try {
      ref.read(appStoresProvider).ledger.recordOp('upscale', 7);
    } catch (_) {}
  }

  // NAI 固定 4×:结果尺寸即输入 ×4。
  return (png: out, width: width * 4, height: height * 4);
}
