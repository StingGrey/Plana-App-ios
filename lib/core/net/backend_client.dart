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

/// 个人云端 Vibe 列表项(`GET /api/user-vibes/list`,不含图片/编码本体)。
/// [imageHash] / [metaHash] 由后端算出,恢复时与本地存的上次同步值比对定去留。
class CloudVibeMeta {
  CloudVibeMeta({
    required this.id,
    required this.name,
    required this.filename,
    this.supportedModels = const [],
    this.defaultStrength,
    this.defaultInfoExtracted,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.tags = const [],
    this.hasImage = true,
    this.imageHash,
    this.metaHash,
  });

  final String id;
  final String name;
  final String filename;
  final List<String> supportedModels;
  final double? defaultStrength;
  final double? defaultInfoExtracted;
  final int createdAt;
  final int updatedAt;
  final List<String> tags;
  final bool hasImage;
  final String? imageHash;
  final String? metaHash;

  /// 缺 filename 的条目无法取文件,直接丢弃(后端理论上不会给,防脏数据)。
  static CloudVibeMeta? fromJson(Map<String, dynamic> j) {
    final filename = j['filename'];
    if (filename is! String || filename.isEmpty) return null;
    return CloudVibeMeta(
      id: j['id']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      filename: filename,
      supportedModels: j['supportedModels'] is List
          ? [
              for (final m in j['supportedModels'] as List)
                if (m is String) m,
            ]
          : const [],
      defaultStrength: (j['defaultStrength'] as num?)?.toDouble(),
      defaultInfoExtracted: (j['defaultInfoExtracted'] as num?)?.toDouble(),
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      tags: j['tags'] is List
          ? [
              for (final t in j['tags'] as List)
                if (t is String) t,
            ]
          : const [],
      hasImage: j['hasImage'] != false,
      imageHash: j['image_hash'] as String?,
      metaHash: j['meta_hash'] as String?,
    );
  }
}

/// 备份/恢复操作记录一条(`GET /api/user-vibes/backup-log`)。
class BackupLogEntry {
  BackupLogEntry({
    required this.device,
    required this.action,
    required this.time,
    required this.count,
    required this.detail,
  });

  final String device;

  /// `backup` | `restore`
  final String action;

  /// unix 秒。
  final int time;
  final int count;
  final String detail;

  bool get isBackup => action == 'backup';

  factory BackupLogEntry.fromJson(Map<String, dynamic> j) => BackupLogEntry(
    device: j['device']?.toString() ?? '未知设备',
    action: j['action']?.toString() ?? 'backup',
    time: (j['time'] as num?)?.toInt() ?? 0,
    count: (j['vibe_count'] as num?)?.toInt() ?? 0,
    detail: j['detail']?.toString() ?? '',
  );
}

/// 公共画师串列表项(`GET /api/artists/list`)。
class PublicArtistMeta {
  PublicArtistMeta({
    required this.id,
    required this.name,
    required this.artistString,
    this.negative = '',
    this.previewUrl,
    this.usageCount = 0,
    this.createdTime = 0,
    this.addedBy,
    this.ownerId,
  });

  final String id;
  final String name;
  final String artistString;
  final String negative;

  /// 预览图绝对 URL(端点公开;无图为 null)。
  final String? previewUrl;
  final int usageCount;
  final int createdTime; // 秒
  final String? addedBy;
  final String? ownerId;
}

/// 公共 OC(角色)列表项(`GET /api/oc/list`)。
class PublicOcMeta {
  PublicOcMeta({
    required this.enName,
    this.zhName,
    this.aliases = const [],
    required this.tagGroup,
    this.negativePrompt = '',
    this.previewUrl,
    this.createdBy,
    this.ownerId,
    this.createdAt = 0,
  });

  final String enName; // 服务端主键
  final String? zhName;
  final List<String> aliases;
  final String tagGroup;
  final String negativePrompt;
  final String? previewUrl;
  final String? createdBy;
  final String? ownerId;
  final int createdAt; // 秒

  String get displayName =>
      zhName != null && zhName!.isNotEmpty ? zhName! : enName;
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
    Future<http.Response> Function() send, {
    Duration? timeout,
  }) async {
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

  Future<Map<String, dynamic>> _postJson(
    String path, [
    Map<String, dynamic>? body,
    String? bearer,
    Duration? timeout,
  ]) => _handle(
    () => http.post(
      _u(path),
      headers: _headers(bearer),
      body: jsonEncode(body ?? const <String, dynamic>{}),
    ),
    timeout: timeout,
  );

  Future<Map<String, dynamic>> _getJson(
    String path, [
    String? bearer,
    Duration? timeout,
  ]) => _handle(
    () => http.get(_u(path), headers: _headers(bearer)),
    timeout: timeout,
  );

  Future<Map<String, dynamic>> _putJson(
    String path, [
    Map<String, dynamic>? body,
    String? bearer,
    Duration? timeout,
  ]) => _handle(
    () => http.put(
      _u(path),
      headers: _headers(bearer),
      body: jsonEncode(body ?? const <String, dynamic>{}),
    ),
    timeout: timeout,
  );

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
    String sessionId,
  ) async {
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
    final j = await _postJson('/bot/generate', {
      'session_id': sessionId,
      'params': params,
      'image_backend': imageBackend,
    }, sessionId);
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
    final j = await _postJson('/vibe/encode', {
      'image': imageBase64,
      'information_extracted': informationExtracted,
      'model': model,
    }, sessionId);
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
      out.add(
        PublicVibeMeta(
          id: v['id'] is String ? v['id'] as String : filename,
          name: v['name'] is String && (v['name'] as String).isNotEmpty
              ? v['name'] as String
              : filename,
          filename: filename,
          thumbnailUrl: publicVibeThumbUrl(filename),
          supportedModels: v['supportedModels'] is List
              ? [
                  for (final m in v['supportedModels'] as List)
                    if (m is String) m,
                ]
              : const [],
          defaultStrength: (v['defaultStrength'] as num?)?.toDouble(),
          defaultInfoExtracted: (v['defaultInfoExtracted'] as num?)?.toDouble(),
          createdAt: (v['createdAt'] as num?)?.toInt() ?? 0,
          hasImage: v['hasImage'] != false,
          uploaderId: v['uploaderId'] as String?,
        ),
      );
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
      throw BackendException(
        '拉取公共 Vibe 失败(${resp.statusCode})',
        status: resp.statusCode,
      );
    }
    return utf8.decode(resp.bodyBytes);
  }

  /// 上传 Vibe 到公共库(bot 模式;鉴权用 body 里的 session_id,后端自动记录上传者)。
  /// [vibeData] = 完整 .naiv4vibe JSON(含图/编码);[name] 为公共展示名。
  /// → (是否成功, 服务端文件名?, 文案)。非 2xx 抛 [BackendException](带 detail)。
  Future<({bool success, String? filename, String message})> uploadPublicVibe({
    required String sessionId,
    required Map<String, dynamic> vibeData,
    required String name,
  }) async {
    final j = await _postJson(
      '/vibes/upload',
      {'vibe_data': vibeData, 'name': name, 'session_id': sessionId},
      sessionId,
      const Duration(seconds: 30),
    );
    return (
      success: j['success'] == true,
      filename: j['filename'] as String?,
      message: (j['message'] as String?) ?? '',
    );
  }

  // ── 公共画师串 / OC / Tag 云备份(灵感页) ─────────────────

  String? _abs(Object? path) =>
      path is String && path.isNotEmpty ? '$baseUrl$path' : null;

  /// 列出公共画师串(登录:Bearer 头)。
  Future<List<PublicArtistMeta>> listPublicArtists(String sessionId) async {
    final j = await _getJson('/artists/list', sessionId);
    final artists = j['artists'];
    if (artists is! List) return const [];
    return [
      for (final a in artists)
        if (a is Map && a['name'] is String && a['artist_string'] is String)
          PublicArtistMeta(
            id: a['id'] is String ? a['id'] as String : a['name'] as String,
            name: a['name'] as String,
            artistString: a['artist_string'] as String,
            negative: a['negative'] is String ? a['negative'] as String : '',
            previewUrl: _abs(a['preview_url']),
            usageCount: (a['usage_count'] as num?)?.toInt() ?? 0,
            createdTime: (a['created_time'] as num?)?.toInt() ?? 0,
            addedBy: a['added_by'] as String?,
            ownerId: a['owner_id'] as String?,
          ),
    ];
  }

  /// 列出公共 OC(登录:Bearer 头)。
  Future<List<PublicOcMeta>> listPublicOcs(String sessionId) async {
    final j = await _getJson('/oc/list', sessionId);
    final ocs = j['ocs'];
    if (ocs is! List) return const [];
    return [
      for (final o in ocs)
        if (o is Map && o['en_name'] is String && o['tag_group'] is String)
          PublicOcMeta(
            enName: o['en_name'] as String,
            zhName: o['zh_name'] as String?,
            aliases: o['zh_aliases'] is List
                ? [
                    for (final s in o['zh_aliases'] as List)
                      if (s is String) s,
                  ]
                : const [],
            tagGroup: o['tag_group'] as String,
            negativePrompt: o['negative_prompt'] is String
                ? o['negative_prompt'] as String
                : '',
            previewUrl: _abs(o['preview_url']),
            createdBy: o['created_by'] as String?,
            ownerId: o['owner_id'] as String?,
            createdAt: (o['created_at'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  /// 发布 OC 到公共库(登录:Bearer 头)。en_name 缺省由服务端按拼音生成。
  /// → 服务端主键 en_name。失败抛 [BackendException](detail 直出)。
  Future<String> createPublicOc({
    required String sessionId,
    String? enName,
    required String zhName,
    List<String> aliases = const [],
    required String tagGroup,
    String negativePrompt = '',
    String? previewBase64,
    String? createdBy,
  }) async {
    final j = await _postJson(
      '/oc/create',
      {
        if (enName != null && enName.isNotEmpty) 'en_name': enName,
        'zh_name': zhName,
        'zh_aliases': aliases,
        'tag_group': tagGroup,
        'negative_prompt': negativePrompt,
        'preview_base64': ?previewBase64,
        'created_by': ?createdBy,
      },
      sessionId,
      const Duration(seconds: 30),
    );
    final oc = j['oc'];
    final en = oc is Map ? oc['en_name'] : null;
    if (en is! String || en.isEmpty) throw BackendException('发布失败:响应异常');
    return en;
  }

  /// 更新公共 OC(仅归属者;[createdBy] 单传即转让归属)。
  Future<void> updatePublicOc({
    required String sessionId,
    required String enName,
    String? zhName,
    List<String>? aliases,
    String? tagGroup,
    String? negativePrompt,
    String? previewBase64,
    String? createdBy,
  }) async {
    await _handle(
      () => http.put(
        _u('/oc/${Uri.encodeComponent(enName)}'),
        headers: _headers(sessionId),
        body: jsonEncode({
          'zh_name': ?zhName,
          'zh_aliases': ?aliases,
          'tag_group': ?tagGroup,
          'negative_prompt': ?negativePrompt,
          'preview_base64': ?previewBase64,
          'created_by': ?createdBy,
        }),
      ),
      timeout: const Duration(seconds: 30),
    );
  }

  Future<void> deletePublicOc(String sessionId, String enName) async {
    await _handle(
      () => http.delete(
        _u('/oc/${Uri.encodeComponent(enName)}'),
        headers: _headers(sessionId),
      ),
    );
  }

  /// 发布画师串(登录:Bearer 头)。name 缺省服务端自动编号。
  /// → (id, name)。重名/重复内容 400,detail 直出。
  Future<({String id, String name})> createPublicArtist({
    required String sessionId,
    String? name,
    required String artistString,
    String negative = '',
    String? previewBase64,
    String? addedBy,
  }) async {
    final j = await _postJson(
      '/artists/create',
      {
        if (name != null && name.isNotEmpty) 'name': name,
        'artist_string': artistString,
        'negative': negative,
        'preview_base64': ?previewBase64,
        'added_by': ?addedBy,
      },
      sessionId,
      const Duration(seconds: 30),
    );
    final a = j['artist'];
    if (a is! Map || a['name'] is! String) {
      throw BackendException('发布失败:响应异常');
    }
    return (
      id: a['id'] is String ? a['id'] as String : a['name'] as String,
      name: a['name'] as String,
    );
  }

  /// 更新公共画师串(仅归属者;[addedBy] 单传即转让归属)。
  Future<void> updatePublicArtist({
    required String sessionId,
    required String id,
    String? artistString,
    String? negative,
    String? previewBase64,
    String? addedBy,
  }) async {
    await _handle(
      () => http.put(
        _u('/artists/${Uri.encodeComponent(id)}'),
        headers: _headers(sessionId),
        body: jsonEncode({
          'artist_string': ?artistString,
          'negative': ?negative,
          'preview_base64': ?previewBase64,
          'added_by': ?addedBy,
        }),
      ),
      timeout: const Duration(seconds: 30),
    );
  }

  Future<void> deletePublicArtist(String sessionId, String id) async {
    await _handle(
      () => http.delete(
        _u('/artists/${Uri.encodeComponent(id)}'),
        headers: _headers(sessionId),
      ),
    );
  }

  /// 公共画师串使用计数上报(确认插入时调,fire-and-forget,失败不打扰)。
  Future<void> reportArtistUse(String sessionId, String artistId) async {
    try {
      await _postJson(
        '/artists/${Uri.encodeComponent(artistId)}/use',
        null,
        sessionId,
      );
    } catch (_) {}
  }

  /// 拉取个人 Tag 云备份(登录:Bearer 头)。web 端备份可能内嵌 base64
  /// 预览,体积达数十 MB,超时放宽到 60s。
  /// → (四类条目原始 JSON, 更新时间秒, 各类计数)。从未备份过时四类为空数组。
  Future<
    ({Map<String, dynamic> categories, int updatedAt, Map<String, int> counts})
  >
  getTagBackup(String sessionId) async {
    final j = await _getJson(
      '/user-tag-backup',
      sessionId,
      const Duration(seconds: 60),
    );
    final rawCounts = j['counts'];
    return (
      categories: j['categories'] is Map<String, dynamic>
          ? j['categories'] as Map<String, dynamic>
          : const <String, dynamic>{},
      updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
      counts: {
        if (rawCounts is Map)
          for (final e in rawCounts.entries)
            if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      },
    );
  }

  /// 备份/恢复操作日志(与 web 共用一份,按 bot_user_id 存;
  /// ⚠️ 鉴权走 body 里的 session_id)。失败不打扰主流程。
  Future<void> recordBackupLog({
    required String sessionId,
    required String device,
    required String action, // backup | restore
    required int count,
    required String detail,
  }) async {
    try {
      await _postJson('/user-vibes/backup-log', {
        'session_id': sessionId,
        'device': device,
        'action': action,
        'vibe_count': count,
        'detail': detail,
      }, sessionId);
    } catch (_) {}
  }

  /// 上传个人 Tag 云备份(整体覆盖;⚠️ 该端点鉴权走 body 里的 session_id)。
  Future<void> uploadTagBackup({
    required String sessionId,
    required Map<String, List<Map<String, dynamic>>> categories,
  }) async {
    await _postJson(
      '/user-tag-backup',
      {'session_id': sessionId, 'categories': categories},
      sessionId,
      const Duration(seconds: 30),
    );
  }

  // ── 个人云端 Vibe 库(与 web 桌面端共用一份,按 bot_user_id 存)────────
  // Tag 备份是「一个 JSON blob 整体覆盖」,Vibe 不同:云端**逐文件**存放,
  // 所以走列表 + 单文件读写,靠 hash 做增量(vibe 带 base64 原图,重传很贵)。

  /// 云端 vibe 统计(`GET /user-vibes/state`),用于弹层顶部「云端 N 条 · 时间」。
  Future<({int count, int updatedAt})> getUserVibesState(
    String sessionId,
  ) async {
    final j = await _getJson('/user-vibes/state', sessionId);
    return (
      count: (j['count'] as num?)?.toInt() ?? 0,
      updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  /// 云端 vibe 列表(仅元数据 + 双 hash,不含图/编码本体)。
  Future<List<CloudVibeMeta>> listUserVibes(String sessionId) async {
    final j = await _getJson(
      '/user-vibes/list',
      sessionId,
      const Duration(seconds: 30),
    );
    final vibes = j['vibes'];
    if (vibes is! List) return const [];
    return [
      for (final v in vibes)
        if (v is Map<String, dynamic>)
          if (CloudVibeMeta.fromJson(v) case final CloudVibeMeta m) m,
    ];
  }

  /// 拉取单条云端 vibe 完整文件(含 base64 原图与编码,较重)。
  Future<Map<String, dynamic>> getUserVibeFile(
    String sessionId,
    String filename,
  ) async {
    return _getJson(
      '/user-vibes/file/${Uri.encodeComponent(filename)}',
      sessionId,
      const Duration(seconds: 60),
    );
  }

  /// 整包推送一条 vibe(⚠️ 鉴权走 body 里的 session_id)。
  /// [filename] 非空 = 定向覆盖云端该文件;为空时后端按 id 去重,
  /// 找得到同 id 就覆盖那个文件,避免改过名/丢了 cloudFilename 时产生重复。
  Future<
    ({
      bool success,
      String? filename,
      String? imageHash,
      String? metaHash,
      String message,
    })
  >
  uploadUserVibe({
    required String sessionId,
    required Map<String, dynamic> vibeData,
    List<String>? tags,
    String? filename,
  }) async {
    try {
      final j = await _postJson(
        '/user-vibes/upload',
        {
          'session_id': sessionId,
          'vibe_data': vibeData,
          'tags': ?tags,
          'filename': ?filename,
        },
        sessionId,
        const Duration(seconds: 90),
      );
      return (
        success: j['success'] == true,
        filename: j['filename'] as String?,
        imageHash: j['image_hash'] as String?,
        metaHash: j['meta_hash'] as String?,
        message: '',
      );
    } on BackendException catch (e) {
      return (
        success: false,
        filename: null,
        imageHash: null,
        metaHash: null,
        message: e.message,
      );
    }
  }

  /// 只改云端元数据(名称/标签/默认参数),不重传图片。
  Future<({bool success, String? imageHash, String? metaHash})>
  updateUserVibeMeta({
    required String sessionId,
    required String filename,
    String? name,
    List<String>? tags,
    double? defaultStrength,
    double? defaultInfoExtracted,
  }) async {
    try {
      final j =
          await _putJson('/user-vibes/file/${Uri.encodeComponent(filename)}', {
            'session_id': sessionId,
            'name': ?name,
            'tags': ?tags,
            'default_strength': ?defaultStrength,
            'default_info_extracted': ?defaultInfoExtracted,
          }, sessionId);
      return (
        success: j['success'] != false,
        imageHash: j['image_hash'] as String?,
        metaHash: j['meta_hash'] as String?,
      );
    } on BackendException {
      return (success: false, imageHash: null, metaHash: null);
    }
  }

  /// 云端 vibe 标签池。
  Future<List<String>> getUserVibeTagPool(String sessionId) async {
    final j = await _getJson('/user-vibes/tag-pool', sessionId);
    final tags = j['tags'];
    if (tags is! List) return const [];
    return [
      for (final t in tags)
        if (t is String && t.isNotEmpty) t,
    ];
  }

  /// 整体覆盖云端标签池(⚠️ 鉴权走 body 里的 session_id)。
  Future<void> putUserVibeTagPool({
    required String sessionId,
    required List<String> tags,
  }) async {
    await _putJson('/user-vibes/tag-pool', {
      'session_id': sessionId,
      'tags': tags,
    }, sessionId);
  }

  /// 备份/恢复操作记录(最近 20 条,与 web 共用)。失败给空表,不打扰主流程。
  Future<List<BackupLogEntry>> getBackupLog(String sessionId) async {
    try {
      final j = await _getJson('/user-vibes/backup-log', sessionId);
      final log = j['log'];
      if (log is! List) return const [];
      return [
        for (final e in log)
          if (e is Map<String, dynamic>) BackupLogEntry.fromJson(e),
      ];
    } catch (_) {
      return const [];
    }
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

  /// WD Tagger 图片标签反推(bot 模式;登录:Bearer 头)。后端转发 HuggingFace
  /// Space,较慢,给足 2 分钟。⚠️ 失败也返 200,看 success/error。
  /// → (是否成功, 标签串, 识别角色, 文案)
  Future<({bool success, String tags, String character, String message})>
  wdTagger({required String sessionId, required String imageBase64}) async {
    final j = await _postJson(
      '/wd-tagger',
      {'image': imageBase64},
      sessionId,
      const Duration(seconds: 120),
    );
    return (
      success: j['success'] == true,
      tags: (j['tags'] as String?) ?? '',
      character: (j['character'] as String?) ?? '',
      message: (j['error'] as String?) ?? '',
    );
  }
}

/// 用当前后端基址构造 client(基址变更自动重建)。
final backendClientProvider = Provider<BackendClient>((ref) {
  final base = ref.watch(backendBaseProvider).value ?? '';
  return BackendClient(base);
});
