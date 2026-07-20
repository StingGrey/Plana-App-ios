import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'backend_client.dart';

/// 跑一个 bot 生成任务的实时链路:WebSocket `/ws/bot`(逐步进度 + 中间预览图)
/// 为主,HTTP 轮询 `GET /api/bot/task/{id}` 为兜底(防 WS 丢消息/连不上)。
/// 首个到达完成/失败的通道胜出。返回最终结果 PNG 字节;失败抛 [BackendException]。
///
/// - [onProgress] `(step, total, preview?)`:逐步进度,WS 携带预览图 base64。
/// - [onQueue] `(queuePos)`:排队中。
/// - [onStage] `(note)`:特殊阶段文案(anima Modal 冷启动 status=starting)。
Future<Uint8List> streamBotTask({
  required String baseUrl,
  required String sessionId,
  required String taskId,
  required BackendClient client,
  void Function(int step, int total, Uint8List? preview)? onProgress,
  void Function(int queuePos)? onQueue,
  void Function(String note)? onStage,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final completer = Completer<Uint8List>();
  var lastStep = -1;

  void done(Uint8List bytes) {
    if (!completer.isCompleted) completer.complete(bytes);
  }

  void fail(Object e) {
    if (!completer.isCompleted) {
      completer.completeError(e is BackendException ? e : BackendException('$e'));
    }
  }

  // 单调递增守卫:防 WS/轮询交错导致进度回退。
  void progress(int step, int total, Uint8List? preview) {
    if (step < lastStep) return;
    lastStep = step;
    onProgress?.call(step, total, preview);
  }

  WebSocket? ws;
  StreamSubscription<dynamic>? wsSub;
  Timer? heartbeat;

  void handle(dynamic raw) {
    Map<String, dynamic> m;
    try {
      final d = jsonDecode(raw as String);
      if (d is! Map<String, dynamic>) return;
      m = d;
    } catch (_) {
      return;
    }
    switch (m['action']) {
      case 'task_progress':
        Uint8List? pv;
        final p = m['preview'];
        if (p is String && p.isNotEmpty) {
          try {
            pv = base64Decode(p);
          } catch (_) {}
        }
        progress((m['step'] as num?)?.toInt() ?? 0,
            (m['total_steps'] as num?)?.toInt() ?? 0, pv);
        break;
      case 'task_update':
        switch (m['status']) {
          case 'completed':
            final r = m['result'];
            final b64 = (r is Map) ? r['imageBase64'] as String? : null;
            if (b64 != null && b64.isNotEmpty) {
              try {
                done(base64Decode(b64));
              } catch (_) {
                fail(BackendException('结果解码失败'));
              }
            }
            break;
          case 'failed':
          case 'cancelled':
            fail(BackendException((m['error'] as String?) ?? '生成失败'));
            break;
          case 'queued':
            onQueue?.call((m['queue_position'] as num?)?.toInt() ?? 0);
            break;
          case 'starting': // anima:Modal 容器冷启动(约 20~60 秒)
            onStage?.call('模型启动中…');
            break;
        }
        break;
    }
  }

  // —— WS 主链路(连不上就纯靠轮询兜底)——
  try {
    final wsUrl = '${baseUrl.replaceFirst(RegExp(r'^http'), 'ws')}/ws/bot';
    ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 12));
    wsSub = ws.listen(handle, onError: (_) {}, onDone: () {});
    ws.add(jsonEncode({'action': 'bind_session', 'session_id': sessionId}));
    ws.add(jsonEncode({'action': 'subscribe_task', 'task_id': taskId}));
    heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
      try {
        ws?.add(jsonEncode({'action': 'heartbeat'}));
      } catch (_) {}
    });
  } catch (_) {
    // 忽略:轮询兜底仍会跑
  }

  // —— HTTP 轮询兜底(每 2.5s)——
  final poll = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
    if (completer.isCompleted) return;
    try {
      final t = await client.getTask(sessionId: sessionId, taskId: taskId);
      if (!t.success) return; // 尚未可见,继续
      if (t.completed) {
        final b64 = t.imageBase64;
        if (b64 != null && b64.isNotEmpty) done(base64Decode(b64));
      } else if (t.failed) {
        fail(BackendException(t.error ?? '生成失败'));
      } else if (t.status == 'queued') {
        onQueue?.call(t.queuePosition);
      } else if (t.status == 'starting') {
        onStage?.call('模型启动中…');
      } else {
        progress(t.step, t.totalSteps, null);
      }
    } on BackendException catch (e) {
      if (e.status == 401) fail(e); // 会话失效直接终止
    } catch (_) {}
  });

  try {
    return await completer.future.timeout(timeout);
  } on TimeoutException {
    throw BackendException('生成超时,请稍后在图库确认');
  } finally {
    poll.cancel();
    heartbeat?.cancel();
    await wsSub?.cancel();
    await ws?.close();
  }
}
