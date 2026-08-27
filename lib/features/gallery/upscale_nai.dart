import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/nai_client.dart';
import '../../core/store/app_stores.dart';
import 'upscale_model.dart';

/// NAI 官方超分。按当前授权模式分发:
///  - bot:走后端 `/api/upscale`(Bearer 会话)。
///  - 直连:app 直打 NAI(Bearer 用户 token),解 zip。
///
/// [v5] = 走 V5 扩散超分那条线(image 子域,固定 ×2、输入尺寸无白名单、按源图
/// 1–4 点);false 则是传统超分(api 子域,4×,尺寸白名单)。两个端点在 NAI 侧
/// **并存**,不是新旧替代关系,所以这里是分流不是升级。
///
/// 输入原图 PNG + 尺寸(传统超分须为白名单分辨率,调用方先校验);
/// 返回 (超分 PNG, 结果宽高)。远程一次性调用无逐步进度 —— 只经 [onStage] 报阶段。
Future<({Uint8List png, int width, int height})> upscaleNai(
  WidgetRef ref,
  Uint8List srcPng, {
  required int width,
  required int height,
  bool v5 = false,
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
          scale: v5 ? 2 : 4,
          mode: v5 ? 'nai5' : 'legacy',
          model: v5 ? kNaiV5UpscaleModel : null,
          declaredBlurSigma: v5 ? 0 : null,
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
    final client = ref.read(naiClientProvider);
    out = v5
        ? await client.upscaleV5(token: token, imageBase64: b64)
        : await client.upscale(
            token: token,
            imageBase64: b64,
            width: width,
            height: height,
          );
    onStage?.call('接收结果…');
    // 本机记账(bot 模式由服务端记):传统 4× 固定 7 点(用户实测确认);
    // V5 扩散超分按**源图**像素查表 1–4 点。
    try {
      final pts = v5 ? (naiV5UpscalePrice(width, height) ?? 4) : 7;
      ref.read(appStoresProvider).ledger.recordOp('upscale', pts);
    } catch (_) {}
  }

  final size = v5
      ? naiV5UpscaleTargetSize(width, height)
      : (w: width * 4, h: height * 4);
  return (png: out, width: size.w, height: size.h);
}
