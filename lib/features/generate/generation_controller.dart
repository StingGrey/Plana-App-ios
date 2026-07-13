import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/token_store.dart';
import '../../core/live_progress/live_progress.dart';
import '../../core/net/anlas_provider.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/backend_config.dart';
import '../../core/net/bot_stream.dart';
import '../../core/net/nai_client.dart';
import '../../core/util/image_ops.dart';
import '../gallery/gallery_state.dart';
import '../gallery/models.dart' show ResultBadge;
import '../inpaint/inpaint_ops.dart';
import '../shell/shell_state.dart';
import 'bot_request.dart';
import 'generate_state.dart';
import 'loop_controller.dart';
import 'models.dart';
import 'nai_request.dart';
import 'prompt_presets.dart';
import 'vibe_encoder.dart';
import '../vibe_library/naiv4vibe_codec.dart' show kModelToEncodingKey;
import '../vibe_library/vibe_library.dart';

/// 生成状态。error 为哨兵 `no-token` 时表示未设置令牌(引导去我的页)。
/// busy 期间 step/total/preview 驱动图库的「生成中」画布。
class GenStatus {
  const GenStatus({
    this.busy = false,
    this.error,
    this.step = 0,
    this.total = 0,
    this.width = 0,
    this.height = 0,
    this.preview,
    this.note,
  });

  final bool busy;
  final String? error;
  final int step;
  final int total;
  final int width;
  final int height;
  final Uint8List? preview;

  /// 进度未知阶段的状态文案(bot 排队「排队中 · 第 N 位」等),
  /// 画布进度胶囊优先显示;null 时显「准备中」。
  final String? note;

  bool get noToken => error == 'no-token';

  /// 0..1;未知(未开始出图)时为 null → 走不确定进度。
  double? get progress =>
      total > 0 && step > 0 ? (step / total).clamp(0.0, 1.0) : null;
}

final generationProvider = NotifierProvider<GenerationNotifier, GenStatus>(
  GenerationNotifier.new,
);

class GenerationNotifier extends Notifier<GenStatus> {
  @override
  GenStatus build() => const GenStatus();

  DateTime? _lastPush; // 通知节流游标

  bool get _appForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// 激活的提示词预设作为前缀拼进正/负提示词(web buildGenerateParams 同款)。
  /// 只用于构造请求;入库仍存原始提示词,避免「重新生成」时二次拼接。
  Future<(GenerateState, String)> _applyPreset(GenerateState s) async {
    final ps = await ref.read(promptPresetsProvider.future);
    final p = ps.active;
    if (p == null || (p.positive.isEmpty && p.negative.isEmpty)) {
      return (s, ps.activeId);
    }
    return (
      s.copyWith(
        prompt: joinPresetPrefix(p.positive, s.prompt),
        negativePrompt: joinPresetPrefix(p.negative, s.negativePrompt),
      ),
      ps.activeId,
    );
  }

  /// [using] 非空时用该快照跑(图库「重新生成」按本图参数复现),不动用户当前编辑器状态。
  /// 返回本张是否成功(循环控制器据此决定续跑/中止)。
  Future<bool> generate({GenerateState? using}) async {
    if (state.busy) return false;

    final GenerateState s = using ?? ref.read(generateProvider);

    // bot 模式:走后端代理生成(提交任务 → 轮询 → base64 入库)
    if (ref.read(authModeProvider).value == AuthMode.bot) {
      return _generateViaBot(s);
    }

    // 等 storage 读完再判(懒加载 AsyncNotifier 冷启动首读是 loading,
    // 直接取 .value 会把「还没读出来」误判成「没配置」)。
    final token = await ref.read(tokenProvider.future);
    if (token == null || token.isEmpty) {
      state = const GenStatus(error: 'no-token'); // 停在创作页,弹「去设置」
      return false;
    }

    final total = s.params.steps;

    // 点生成即切图库,边生成边看逐步预览;循环续张不再强拉
    // (循环开始时已切过一次,期间允许用户自由切页,真机反馈)
    if (!_inLoop) ref.read(shellIndexProvider.notifier).select(1);
    state = GenStatus(
      busy: true,
      total: total,
      width: s.params.width,
      height: s.params.height,
    );

    // 后台进度:开前台服务 + 常驻/可上岛通知(纯锦上添花,失败不影响生成)
    _lastPush = null;
    await LiveProgress.instance.ensurePermission();
    await LiveProgress.instance.start(text: '$_loopPrefix准备生成…');

    ({Map<String, dynamic> body, int seed})? built;

    Future<void> finish(Uint8List bytes, int seed) async {
      await _storeResult(s, bytes, seed);
      state = const GenStatus();
      ref.read(anlasProvider.notifier).refresh(); // 点数已扣
      // 循环期间通知由循环控制器统一收尾(保持挂机进度连续、只弹一条汇总)
      if (!_inLoop) _endIsland(success: true);
    }

    try {
      // 1. 先编码启用的 Vibe 参考(缓存优先;每次新编码费 2 Anlas)
      final prepared = await _prepareVibes(s);
      // 2. 图生图底图 cover 到目标分辨率
      final img2img = await _processImg2Img(s);
      // 3. 角色参考:contain 处理底图(无编码调用,载荷层按模型 gate)
      final charRefs = await _processCharRefs(s);
      // 4. 拼载荷 + 流式生成
      final (sp, presetId) = await _applyPreset(s);
      built = buildNaiPayload(
        sp,
        presetId: presetId,
        vibes: [
          for (final v in prepared) (encoded: v.encoded, strength: v.strength),
        ],
        img2img: img2img,
        charRefs: charRefs,
      );
      Uint8List? last;
      await for (final f
          in ref
              .read(naiClientProvider)
              .generateImageStream(token: token, body: built.body)) {
        last = f.bytes;
        final step = f.isFinal ? total : (f.step ?? 0);
        state = GenStatus(
          busy: true,
          total: total,
          width: s.params.width,
          height: s.params.height,
          step: step,
          preview: f.bytes,
        );
        _pushProgress(step, total);
        if (f.isFinal) break;
      }
      if (last == null) throw NaiException('未收到图片数据');
      await finish(last, built.seed);
      return true;
    } on NaiException catch (e) {
      debugPrint('[gen] NaiException status=${e.status} ${e.message}');
      // 流式端点不可用(404/405 = 请求没被受理,未扣点)→ 非流式回退
      if ((e.status == 404 || e.status == 405) && built != null) {
        try {
          final bytes = await ref
              .read(naiClientProvider)
              .generateImage(token: token, body: built.body);
          await finish(bytes, built.seed);
          return true;
        } on NaiException catch (e2) {
          debugPrint('[gen] fallback failed status=${e2.status} ${e2.message}');
          state = GenStatus(error: e2.message);
          if (!_inLoop) _endIsland(success: false);
          return false;
        }
      }
      state = GenStatus(error: e.message);
      if (!_inLoop) _endIsland(success: false);
      return false;
    } catch (e) {
      debugPrint('[gen] $e');
      state = GenStatus(error: '生成失败:$e');
      if (!_inLoop) _endIsland(success: false);
      return false;
    }
  }

  // ---- 循环上下文(通知文案注入「第 n/N 张」;非循环时为空串) ----

  /// 循环运行中:单张不撤/不留通知,收尾归循环控制器。
  bool get _inLoop => ref.read(loopStatusProvider).active;

  String get _loopPrefix {
    final lp = ref.read(loopStatusProvider);
    if (!lp.active) return '';
    return lp.total > 0
        ? '第 ${lp.batch}/${lp.total} 张 · '
        : '第 ${lp.batch} 张 · ';
  }

  /// 循环中状态栏胶囊改显张数(挂机时比步数有用)。
  String get _loopShort {
    final lp = ref.read(loopStatusProvider);
    if (!lp.active) return '';
    return lp.total > 0 ? '${lp.batch}/${lp.total}' : '${lp.batch}·∞';
  }

  /// 进度推到通知,≤~1/s 节流(系统对通知更新有限流,终帧必推)。
  void _pushProgress(int step, int total) {
    final finalish = total > 0 && step >= total;
    final now = DateTime.now();
    if (!finalish &&
        _lastPush != null &&
        now.difference(_lastPush!).inMilliseconds < 800) {
      return;
    }
    _lastPush = now;
    final ls = _loopShort;
    if (step <= 0) {
      LiveProgress.instance.update(
        indeterminate: true,
        text: '$_loopPrefix生成中…',
        short: ls.isEmpty ? '…' : ls,
      );
    } else {
      LiveProgress.instance.update(
        step: step,
        total: total,
        text: '$_loopPrefix生成中 $step/$total',
        short: ls.isEmpty ? '$step/$total' : ls,
      );
    }
  }

  /// 收尾:前台静默撤通知;后台留一条完成/失败态,可点按回应用。
  void _endIsland({required bool success}) {
    if (_appForeground) {
      LiveProgress.instance.stop();
    } else {
      LiveProgress.instance.finish(text: success ? '生成完成 · 点按查看' : '生成失败');
    }
  }

  /// bot 模式:后端代理生成。编码 vibe(缓存)→ 提交任务 → WS 流式(逐步预览)
  /// + 轮询兜底 → base64 入库 → 刷新点数。CR / 图生图与直连同一套离线处理。
  Future<bool> _generateViaBot(GenerateState s) async {
    // 同 generate():await future,避免冷启动 loading 态误报未授权/未配置。
    final session = await ref.read(botSessionProvider.future);
    if (session == null) {
      state = const GenStatus(error: '尚未 Bot 授权,请在「我的」页完成授权');
      return false;
    }
    final base = await ref.read(backendBaseProvider.future);
    if (base.isEmpty) {
      state = const GenStatus(error: '未配置后端地址,请在「我的」页或授权页填写');
      return false;
    }

    final total = s.params.steps;
    // 同 generate():循环续张不强拉图库
    if (!_inLoop) ref.read(shellIndexProvider.notifier).select(1);
    state = GenStatus(
      busy: true,
      total: total,
      width: s.params.width,
      height: s.params.height,
    );
    _lastPush = null;
    await LiveProgress.instance.ensurePermission();
    await LiveProgress.instance.start(text: '$_loopPrefix准备生成…');

    final client = ref.read(backendClientProvider);
    final seed = _resolveSeed(s.params.seed);

    try {
      // 参考图:CR / 图生图离线处理;vibe 走统一编码服务(缓存,避免重复扣 2 Anlas)
      final img2img = await _processImg2Img(s);
      final charRefs = await _processCharRefs(s);
      final prepared = await _prepareVibes(s);
      final (sp, presetId) = await _applyPreset(s);
      final params = buildBotParams(
        sp,
        seed: seed,
        presetId: presetId,
        img2img: img2img,
        charRefs: charRefs,
        vibes: [
          for (final v in prepared)
            (
              encodedVibe: v.encoded,
              strength: v.strength,
              infoExtracted: v.infoExtracted,
            ),
        ],
      );

      final sub = await client.botGenerate(
        sessionId: session.sessionId,
        params: params,
      );
      if (!sub.success || sub.taskId == null || sub.taskId!.isEmpty) {
        throw BackendException(sub.message.isEmpty ? '任务提交失败' : sub.message);
      }

      // 流式:WS 逐步预览 + 轮询兜底
      final bytes = await streamBotTask(
        baseUrl: base,
        sessionId: session.sessionId,
        taskId: sub.taskId!,
        client: client,
        onProgress: (step, tot, preview) {
          final t = tot > 0 ? tot : total;
          state = GenStatus(
            busy: true,
            total: t,
            width: s.params.width,
            height: s.params.height,
            step: step,
            preview: preview ?? state.preview,
          );
          _pushProgress(step, t);
        },
        onQueue: (pos) {
          // 轮询兜底可能晚于 WS 进度到达:已在出图就忽略迟到的排队消息
          if (state.step > 0) return;
          final text = pos > 0 ? '排队中 · 第 $pos 位' : '排队中';
          state = GenStatus(
            busy: true,
            total: total,
            width: s.params.width,
            height: s.params.height,
            note: text,
          );
          _pushIndeterminate(text);
        },
      );

      await _storeResult(s, bytes, seed);
      state = const GenStatus();
      ref.read(anlasProvider.notifier).refresh(); // 生成后刷新点数(对齐 web)
      if (!_inLoop) _endIsland(success: true);
      return true;
    } on BackendException catch (e) {
      state = GenStatus(error: e.message);
      if (!_inLoop) _endIsland(success: false);
      return false;
    } catch (e) {
      debugPrint('[gen/bot] $e');
      state = GenStatus(error: '生成失败:$e');
      if (!_inLoop) _endIsland(success: false);
      return false;
    }
  }

  /// 启用的 Vibe → 编码串+参数,直连/bot 共用(统一编码服务:内容寻址缓存
  /// 优先,miss 按当前授权线现场编码扣 2 Anlas)。
  /// 纯编码 vibe(库导入、无原图)直接取当前模型的编码,取不到则跳过。
  Future<List<({String encoded, double strength, double infoExtracted})>>
      _prepareVibes(GenerateState s) async {
    final vibes = s.vibes.where((v) => v.enabled).toList();
    if (vibes.isEmpty) return const [];
    final model = naiModelId(s.params.model);
    final encoder = ref.read(vibeEncoderProvider);
    final out = <({String encoded, double strength, double infoExtracted})>[];
    for (final v in vibes) {
      final img = v.image;
      final String enc;
      if (img != null) {
        // 哈希缺失(不应发生)时现算,保证仍走缓存不重复扣点
        final hash = v.imageHash ?? sha256HexOfBytes(img);
        enc = await encoder.encode(
          image: img,
          imageHash: hash,
          model: model,
          infoExtracted: v.infoExtracted,
        );
      } else {
        final byModel = v.encodedByModel?[kModelToEncodingKey[model] ?? model];
        if (byModel == null) {
          debugPrint('[vibe] ${v.name} 无 $model 编码且无原图,跳过');
          continue;
        }
        enc = byModel;
      }
      out.add((
        encoded: enc,
        strength: v.strength,
        infoExtracted: v.infoExtracted,
      ));
    }
    return out;
  }

  int _resolveSeed(String seedStr) {
    final v = seedStr.trim();
    if (v.isEmpty) return Random().nextInt(4294967296);
    return int.tryParse(v) ?? Random().nextInt(4294967296);
  }

  /// 不确定态进度(排队中),≤~1/s 节流。
  void _pushIndeterminate(String text) {
    final now = DateTime.now();
    if (_lastPush != null && now.difference(_lastPush!).inMilliseconds < 800) {
      return;
    }
    _lastPush = now;
    final ls = _loopShort;
    LiveProgress.instance.update(
      indeterminate: true,
      text: '$_loopPrefix$text',
      short: ls.isEmpty ? '…' : ls,
    );
  }

  /// 图生图底图:cover 到当前目标分辨率 → PNG base64。无底图返回 null。
  /// 快照带重绘任务时跳过(重绘与图生图互斥,inpaint 优先)。
  Future<Img2ImgRef?> _processImg2Img(GenerateState s) async {
    if (s.inpaint != null) return null;
    final cfg = s.img2img;
    final img = cfg?.image;
    if (cfg == null || img == null) return null;
    final png = await coverResizePng(img, s.params.width, s.params.height);
    return (image: base64Encode(png), strength: cfg.strength, noise: cfg.noise);
  }

  /// 结果入库(直连/bot 共用):局部重绘先把结果贴回原图,
  /// 重绘任务统一打「重绘」角标;快照原样入库供「重新生成」复现。
  Future<void> _storeResult(GenerateState s, Uint8List bytes, int seed) async {
    final job = s.inpaint;
    var out = bytes;
    var w = s.params.width;
    var h = s.params.height;
    final paste = job?.paste;
    if (paste != null) {
      try {
        out = await pasteBack(
          original: paste.original,
          patch: bytes,
          send: (x: paste.sendX, y: paste.sendY, w: w, h: h),
          tight: (
            x: paste.tightX,
            y: paste.tightY,
            w: paste.tightW,
            h: paste.tightH,
          ),
        );
        w = paste.outW;
        h = paste.outH;
      } catch (e) {
        debugPrint('[gen] pasteBack failed: $e'); // 贴回失败退化为子图入库
      }
    }
    ref
        .read(galleryProvider.notifier)
        .addResult(
          bytes: out,
          width: w,
          height: h,
          seed: seed,
          badge: job != null ? ResultBadge.inpaint : ResultBadge.none,
          input: s, // 参数快照,供图库「重新生成」按本图参数复现
        );
    // 库来源的 vibe 回写「最近使用」(fire-and-forget,失败无害)
    final usedVibeIds = {
      for (final v in s.vibes)
        if (v.enabled && v.sourceId != null) v.sourceId!,
    };
    if (usedVibeIds.isNotEmpty) {
      ref.read(vibeLibraryProvider.notifier).markUsed(usedVibeIds);
    }
  }

  /// 角色参考:每张启用且有图的 contain 处理成 PNG base64(无编码调用、免 Anlas)。
  /// 是否真正下发由载荷层按模型 gate(仅 4.5)。
  Future<List<CharRefPayload>> _processCharRefs(GenerateState s) async {
    final refs = s.charRefs.where((r) => r.enabled && r.image != null).toList();
    if (refs.isEmpty) return const [];
    final out = <CharRefPayload>[];
    for (final r in refs) {
      final png = await crResizePng(r.image!);
      out.add((
        image: base64Encode(png),
        mode: r.mode.api,
        strength: r.strength,
        fidelity: r.infoExtracted,
      ));
    }
    return out;
  }

  void clearError() {
    if (state.error != null) state = const GenStatus();
  }
}
