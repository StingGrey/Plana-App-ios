import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'backend_config.dart';

/// 后端请求失败(网络/非 2xx/格式)。`message` 为可直接展示的人类可读文案。
class BackendException implements Exception {
  BackendException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// bot 模式一次任务查询的快照(`GET /api/bot/task/{id}`)。
class BotTask {
  BotTask({
    required this.success,
    this.status,
    this.step = 0,
    this.totalSteps = 0,
    this.imageBase64,
    this.error,
    this.queuePosition = 0,
  });

  final bool success; // 任务是否存在
  final String? status; // queued/starting/generating/completed/failed/cancelled
  final int step;
  final int totalSteps;
  final String? imageBase64; // 完成时的结果图
  final String? error;
  final int queuePosition;

  bool get completed => status == 'completed';
  bool get failed => status == 'failed' || status == 'cancelled';

  factory BotTask.fromJson(Map<String, dynamic> j) {
    final result = j['result'];
    String? img;
    if (result is Map && result['imageBase64'] is String) {
      img = result['imageBase64'] as String;
    }
    return BotTask(
      success: j['success'] == true,
      status: j['status'] as String?,
      step: (j['step'] as num?)?.toInt() ?? 0,
      totalSteps: (j['total_steps'] as num?)?.toInt() ?? 0,
      imageBase64: img,
      error: j['error'] as String?,
      queuePosition: (j['queue_position'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 公共 Vibe 库列表项(`GET /api/vibes/list`,不含图片/编码本体)。
class PublicVibeMeta {
  PublicVibeMeta({
    required this.id,
    required this.name,
    required this.filename,
    required this.thumbnailUrl,
    this.supportedModels = const [],
    this.defaultStrength,
    this.defaultInfoExtracted,
    this.createdAt = 0,
    this.hasImage = true,
    this.uploaderId,
  });

  final String id;
  final String name;
  final String filename;

  /// 公开缩略图端点绝对 URL(直接喂 Image.network)。
  final String thumbnailUrl;
  final List<String> supportedModels;
  final double? defaultStrength;
  final double? defaultInfoExtracted;
  final int createdAt;
  final bool hasImage;
  final String? uploaderId;
}

/// Plana 后端客户端(当前仅含 bot 授权四端点里 App 要用的三个;
/// verify 由 Bot 侧调用,App 不实现)。契约见 docs/api/auth-bot.md。
///
/// 全站约定:auth 端点失败也返 200,要看 body 的 verified/valid 字段;
/// 其余端点非 2xx + `{"detail": ...}`。
class BackendClient {
  BackendClient(this.baseUrl);

  /// 形如 `http://host:8765`,末尾无斜杠。
  final String baseUrl;

  static const _timeout = Duration(seconds: 15);

  Uri _u(String path) => Uri.parse('$baseUrl/api$path');

  Map<String, String> _headers([String? bearer]) => {
        'Content-Type': 'application/json',
        if (bearer != null) 'Authorization': 'Bearer $bearer',
      };

  Future<Map<String, dynamic>> _handle(
      Future<http.Response> Function() send, {Duration? timeout}) async {
    if (baseUrl.isEmpty) throw BackendException('未配置后端地址');
    final http.Response resp;
    try {
      resp = await send().timeout(timeout ?? _timeout);
    } on TimeoutException {
      throw BackendException('连接后端超时,请检查地址与网络');
    } catch (_) {
      throw BackendException('无法连接后端,请检查地址与网络');
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      var detail = '请求失败(${resp.statusCode})';
      try {
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        if (j is Map && j['detail'] is String) detail = j['detail'] as String;
      } catch (_) {}
      throw BackendException(detail, status: resp.statusCode);
    }

    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    throw BackendException('后端返回格式异常');
  }

  Future<Map<String, dynamic>> _postJson(String path,
          [Map<String, dynamic>? body, String? bearer, Duration? timeout]) =>
      _handle(
          () => http.post(_u(path),
              headers: _headers(bearer),
              body: jsonEncode(body ?? const <String, dynamic>{})),
          timeout: timeout);

  Future<Map<String, dynamic>> _getJson(String path, [String? bearer]) =>
      _handle(() => http.get(_u(path), headers: _headers(bearer)));

  /// 发起授权码(标记来源 app,授权成功时 Bot 提示会显示「NovelAI App」)。
  /// → (6 位大写 hex code, 有效期秒数)
  Future<({String code, int expiresIn})> authGenerate() async {
    final j = await _postJson('/bot/auth/generate', {'source': 'app'});
    final code = j['code'] as String?;
    if (code == null || code.isEmpty) throw BackendException('未获取到授权码');
    return (code: code, expiresIn: (j['expires_in'] as num?)?.toInt() ?? 300);
  }

  /// 轮询授权码是否已被 Bot 验证。→ (是否已验证, session_id?)
  Future<({bool verified, String? sessionId})> authCheck(String code) async {
    final j = await _postJson('/bot/auth/check', {'code': code});
    return (
      verified: j['verified'] == true,
      sessionId: j['session_id'] as String?,
    );
  }

  /// 轻量校验会话并取滑动过期时间。→ (是否有效, 归属 bot_user_id?, 过期毫秒?)
  Future<({bool valid, String? botUserId, int? expiresAtMs})> validate(
      String sessionId) async {
    final j = await _postJson('/bot/auth/validate', {'session_id': sessionId});
    return (
      valid: j['valid'] == true,
      botUserId: j['bot_user_id'] as String?,
      expiresAtMs: (j['expires_at_ms'] as num?)?.toInt(),
    );
  }

  /// 提交 bot 模式生成任务(登录:Bearer 头 + body 里 session_id)。
  /// → (是否受理, task_id?, 文案)。⚠️ 入队失败也返 200 success:false。
  Future<({bool success, String? taskId, String message})> botGenerate({
    required String sessionId,
    required Map<String, dynamic> params,
    String imageBackend = 'novelai',
  }) async {
    final j = await _postJson(
      '/bot/generate',
      {'session_id': sessionId, 'params': params, 'image_backend': imageBackend},
      sessionId,
    );
    return (
      success: j['success'] == true,
      taskId: j['task_id'] as String?,
      message: (j['message'] as String?) ?? '',
    );
  }

  /// 查任务状态(私有:Bearer 头,只能查自己的)。
  Future<BotTask> getTask({
    required String sessionId,
    required String taskId,
  }) async {
    final j = await _getJson('/bot/task/$taskId', sessionId);
    return BotTask.fromJson(j);
  }

  /// 后端编码 Vibe 参考(bot 模式;⚠️ 扣 2 Anlas,务必缓存)。
  /// → `encoding` 串,填进生成 `params.vibeReferences[].encodedVibe`。
  Future<String> encodeVibe({
    required String sessionId,
    required String imageBase64,
    required double informationExtracted,
    required String model,
  }) async {
    final j = await _postJson(
      '/vibe/encode',
      {
        'image': imageBase64,
        'information_extracted': informationExtracted,
        'model': model,
      },
      sessionId,
    );
    final enc = j['encoding'] as String?;
    if (enc == null || enc.isEmpty) throw BackendException('Vibe 编码失败');
    return enc;
  }

  /// 服务账户 Anlas 余额(公开端点,共享池;bot 模式头部显示,对齐 web)。
  Future<int> getAnlas() async {
    final j = await _getJson('/anlas');
    return (j['anlas'] as num?)?.toInt() ?? 0;
  }

  // ── 公共 Vibe 库(契约见 docs/api/library.md) ────────────────

  /// 缩略图端点绝对 URL(公开,`<img>`/Image.network 直接引用)。
  String publicVibeThumbUrl(String filename) =>
      '$baseUrl/api/vibes/thumbnail/${Uri.encodeComponent(filename)}';

  /// 列出公共 Vibe(登录:Bearer 头)。仅元数据 + 缩略图 URL,不含图/编码。
  Future<List<PublicVibeMeta>> listPublicVibes(String sessionId) async {
    final j = await _getJson('/vibes/list', sessionId);
    final vibes = j['vibes'];
    if (vibes is! List) return const [];
    final out = <PublicVibeMeta>[];
    for (final v in vibes) {
      if (v is! Map) continue;
      final filename = v['filename'];
      if (filename is! String || filename.isEmpty) continue;
      out.add(PublicVibeMeta(
        id: v['id'] is String ? v['id'] as String : filename,
        name: v['name'] is String && (v['name'] as String).isNotEmpty
            ? v['name'] as String
            : filename,
        filename: filename,
        thumbnailUrl: publicVibeThumbUrl(filename),
        supportedModels: v['supportedModels'] is List
            ? [
                for (final m in v['supportedModels'] as List)
                  if (m is String) m
              ]
            : const [],
        defaultStrength: (v['defaultStrength'] as num?)?.toDouble(),
        defaultInfoExtracted: (v['defaultInfoExtracted'] as num?)?.toDouble(),
        createdAt: (v['createdAt'] as num?)?.toInt() ?? 0,
        hasImage: v['hasImage'] != false,
        uploaderId: v['uploaderId'] as String?,
      ));
    }
    return out;
  }

  /// 拉取公共 Vibe 完整 .naiv4vibe 文件文本(登录:Bearer 头;含图/编码,较重)。
  /// 直接返回原始 JSON 文本,供 [VibeLibrary.importVibeText] 落库。
  Future<String> getPublicVibeFileText(
    String sessionId,
    String filename,
  ) async {
    if (baseUrl.isEmpty) throw BackendException('未配置后端地址');
    final uri = _u('/vibes/file/${Uri.encodeComponent(filename)}');
    final http.Response resp;
    try {
      resp = await http
          .get(uri, headers: _headers(sessionId))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw BackendException('拉取公共 Vibe 超时');
    } catch (_) {
      throw BackendException('无法连接后端');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw BackendException('拉取公共 Vibe 失败(${resp.statusCode})',
          status: resp.statusCode);
    }
    return utf8.decode(resp.bodyBytes);
  }

  /// NAI 官方超分(bot 模式;登录:Bearer 头)。仅支持 832×1216/1216×832/1024² · 4x 扣约 6 点。
  /// 后端要远程转发 NAI,给足 2 分钟超时。⚠️ 失败也返 200,看 success/message。
  /// → (是否成功, 结果图 base64?, 文案)
  Future<({bool success, String? imageBase64, String message})> upscale({
    required String sessionId,
    required String imageBase64,
    required int width,
    required int height,
    int scale = 4,
  }) async {
    final j = await _postJson(
      '/upscale',
      {'image': imageBase64, 'width': width, 'height': height, 'scale': scale},
      sessionId,
      const Duration(seconds: 120),
    );
    return (
      success: j['success'] == true,
      imageBase64: j['image'] as String?,
      message: (j['message'] as String?) ?? '',
    );
  }
}

/// 用当前后端基址构造 client(基址变更自动重建)。
final backendClientProvider = Provider<BackendClient>((ref) {
  final base = ref.watch(backendBaseProvider).value ?? '';
  return BackendClient(base);
});
