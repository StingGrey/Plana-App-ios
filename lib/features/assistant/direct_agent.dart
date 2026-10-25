/// 直连自定义接口那条:在 app 里跑一遍 agent 循环,吐出与 `streamAgentPrompt`
/// 完全一样的 [AgentEvent] 流。
///
/// **下游一个字都不用改**:结果卡、导入、生成、内联出图只认这几个事件和
/// [AgentResult],不知道字节是从 Plana 后端来的还是从用户自己的模型来的。
/// (逐字显示的 [AgentDelta] 目前只有这条发 —— 服务端那条还没开流,见 agent_stream。)
///
/// 三件事和服务端那条对齐,不能自己另发明一套:
///   · **提示词**用规则主体([PresetRule]),与服务端那条是同一份:自定义过就用自定义的,
///     没有就是服务端的默认那份。只是不套外壳 —— 外壳是服务端消息编排用的;
///   · **条件段**(漫画规则这类)发不发,判据与服务端同一条([detectPromptModes]);
///     用户手动选的模式(漫画、仅自然语言)由调用方传进来,挑段规则见 [renderRules];
///   · **本地库**(画师串 / OC)的预匹配、占位符、记账、查库工具**全在手机上做**,
///     库的内容不出本机 —— 见 local_library.dart。模型用的是你自己的接口,没道理把
///     你的库传到 Plana 后端去;
///   · **服务端自己的数据**(角色索引、tag 百科、选了「+ 公共库」时的公共库)还是去后端查,
///     打 `/api/agent/prequery`、`/api/agent/tools/call`,发过去的只有查询词和资料库范围;
///   · **调用约定**(```tool_call 围栏、```nai_draw 围栏)由服务端渲染好的
///     「可用工具」块带过来,app 不拼这段 —— 加一个工具就得两边一起改的话,
///     漏一边的表现是模型调了个不存在的工具。
///
/// 与服务端那条**没有**的:降级阶梯、拒绝重掷、tag 哨兵。跑失败就是失败。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/net/agent_stream.dart';
import '../../core/net/backend_client.dart';
import '../../core/util/image_ops.dart' show styleRefResizeJpg;
import 'agent_trace.dart';
import 'assistant_models.dart' show decodeResources;
import 'assistant_settings.dart';
import 'custom_endpoint.dart';
import 'local_library.dart';
import 'preset_rules.dart';

final _toolFence = RegExp(
  r'```[ \t]*tool_call[ \t]*\r?\n(.*?)```',
  dotAll: true,
  caseSensitive: false,
);
final _drawFence = RegExp(
  r'```[ \t]*nai_draw[ \t]*\r?\n(.*?)```',
  dotAll: true,
  caseSensitive: false,
);
// 写在正文里的思考段。规则让模型用 `<Think>`;推理模型自己带的是 `<think>`(DeepSeek
// 那一系),Gemini 的 OpenAI 兼容口开了思考回的是 `<thought>`,有的中转转 Claude 时
// 包成 `<thinking>` —— 认不出的那几种会原样摊在气泡里。
final _thinkTag = RegExp(
  r'<(think|thinking|thought)>.*?</\1>',
  dotAll: true,
  caseSensitive: false,
);

// 流到一半时切正文用的几把尺子(见 [directStreamView])。整段的 [_thinkTag] 在这里
// 不够用 —— 流中途的 `<Think>` 多半还没收尾,那就得按「开标签之后全是思考」算。
final _thinkOpen = RegExp(r'<(think|thinking|thought)>', caseSensitive: false);
final _liveFenceOpen = RegExp(
  r'```[ \t]*(?:tool_call|nai_draw)',
  caseSensitive: false,
);

/// 收到一半的标签 / 围栏头(`<Thi`、` ```na `)。显示出来是一闪一闪的乱码,
/// 而下一帧它们本来就会被认出来,少显示一帧不亏。
///
/// 反引号后面**必须跟着字母**才算:光秃秃的 ``` 多半是代码块的收尾、`…` 是行内
/// 代码的收尾,切掉反而把好好的块拆了。
final _liveTail = RegExp(r'(?:<[A-Za-z/]{0,9}|`{1,3}[ \t]*[A-Za-z_]{1,9})$');

/// 附图:MIME + base64。
typedef DirectImage = ({String mime, String data});

/// 发给模型的一条消息。[image] 只挂在本轮用户那条上 —— 历史里的图不回带,
/// 与服务端那条一致。
typedef DirectMsg = ({String role, String content, DirectImage? image});

/// 按文件头认图片类型,认不出按 PNG —— 与服务端 `_sniff_image_mime` 同一张表。
/// 标签和字节对不上时有的接口整条拒收,而相册里挑的多半是 JPEG。
String imageMimeOf(Uint8List b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'image/webp';
  if (at(0, 'GIF87a'.codeUnits) || at(0, 'GIF89a'.codeUnits)) {
    return 'image/gif';
  }
  return 'image/png';
}

/// 附图超过这个字节数就先缩再发。
///
/// 卡的是 Claude:单张图 base64 超过 5MB 整条请求被拒,放大过的图随便就过线。
/// 服务端那条原样转发,失败了还有「剥图重试」兜着;直连没有重试,一次就得发得出去。
const kDirectImageMaxBytes = 3500000;

/// 附图 → 发给模型的那份。超过 [kDirectImageMaxBytes] 的按长边 2048 转 JPEG,
/// 画面内容看得清就够写提示词了。转不动(解不开的格式)就原样发,让接口自己判。
Future<DirectImage> prepareDirectImage(Uint8List bytes) async {
  if (bytes.length > kDirectImageMaxBytes) {
    try {
      final jpg = await styleRefResizeJpg(bytes, maxDim: 2048, quality: 90);
      return (mime: 'image/jpeg', data: base64Encode(jpg));
    } catch (_) {}
  }
  return (mime: imageMimeOf(bytes), data: base64Encode(bytes));
}

/// 文字里认得出的完整画师串折成占位符(映射见 [ArtistPlan.tokens])。
///
/// 画布、历史里的画师串都是当初逐字填进去的,逐字比就对得上;用户在创作页改过的对不上,
/// 原样给模型。长的先换,免得短串吃掉长串的一截。
String collapseArtistStrings(String text, Map<String, String> tokens) {
  final entries = [
    for (final e in tokens.entries)
      if (e.value.isNotEmpty) e,
  ]..sort((a, b) => b.value.length.compareTo(a.value.length));
  var out = text;
  for (final e in entries) {
    out = out.replaceAll(e.value, e.key);
  }
  return out;
}

/// 正文里的 ```nai_draw 围栏 → 画面;剥掉围栏和 `<Think>` 之后剩下的就是回复。
///
/// 抽成纯函数是因为模型写坏围栏的花样很多(写成 ```json、忘了收尾的 ```、
/// 一条回复里写两个),而写坏的表现是「这轮没出图」,和「模型决定不出图」
/// 长得一模一样 —— 不单测根本分不出来。
({String reply, Map<String, dynamic>? draw}) parseDirectReply(String raw) {
  var text = raw.replaceAll(_thinkTag, '');
  Map<String, dynamic>? draw;
  // 取**最后**一个围栏:模型偶尔会先写一版再改一版,后写的是它的结论
  for (final m in _drawFence.allMatches(text)) {
    try {
      final j = jsonDecode(m.group(1)!.trim());
      if (j is Map<String, dynamic>) draw = j;
    } catch (_) {
      // 围栏里不是合法 JSON —— 当这轮没出图,正文照常发出去
    }
  }
  text = text.replaceAll(_drawFence, '');
  return (reply: text.trim(), draw: draw);
}

/// 正文里的 ```tool_call 围栏 → 待执行的调用。解析不了的那条跳过,不整轮作废。
List<({String name, Map<String, dynamic> args})> parseToolCalls(String raw) {
  final out = <({String name, Map<String, dynamic> args})>[];
  for (final m in _toolFence.allMatches(raw)) {
    try {
      final j = jsonDecode(m.group(1)!.trim());
      if (j is! Map) continue;
      final name = j['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final args = j['arguments'];
      out.add((
        name: name,
        args: args is Map<String, dynamic> ? args : const {},
      ));
    } catch (_) {
      // 不是合法 JSON:跳过这一块。服务端那条会回灌一条「解析失败」让模型重写,
      // 直连这边不做 —— 没有重试预算的概念,多跑一跳不如让它凭已有信息作答。
    }
  }
  return out;
}

/// 自定义接口那条的系统提示:规则(已挂好工具层) + 出图格式 + 工具表。
///
/// 顺序对着服务端那条:规则主体在前,代码侧的「输出格式」「可用工具」两块在后。
/// [modes] 是预匹配判回来的,[chosen] 是用户选的模式,挑段规则见 [renderRules]。
String directSystemPrompt({
  required List<PresetRule> rules,
  required List<String>? modes,
  List<String> chosen = const [],
  required String outputFormat,
  required String toolsBlock,
}) => [
  renderRules(rules, modes, chosen: chosen),
  outputFormat.trim(),
  toolsBlock.trim(),
].where((s) => s.isNotEmpty).join('\n\n');

/// 跑一轮。事件序列与 [streamAgentPrompt] 一致,最后一个必是 [AgentDone]。
Stream<AgentEvent> streamDirectPrompt({
  required CustomEndpoint endpoint,
  required String backendBase,

  /// 空串 = 没有 Bot 授权。角色候选、服务端工具照样打后端,只是用不了公共库。
  required String sessionId,
  required String userRequest,

  /// 用户这轮附的图(原始字节)。挂在本轮 user 消息上,每一跳都带着。
  Uint8List? image,

  /// 这一轮用的规则(预设 + app 工具层,见 [withToolLayer])。按段给,条件段在这里筛。
  required List<PresetRule> rules,

  /// 出图代码块的格式说明([appOutputFormat])。服务端那条由后端代码发,这条得自己带。
  String outputFormat = '',

  /// 画布那段([当前画面提示词] 块),不带就是这轮不给画布。
  ///
  /// 和 [userRequest] 分开收、拼进同一条 user 消息 —— 与服务端 parts 的形状一致。
  /// **不能让它进预匹配**:整串画布 tag 拿去做字面匹配会把一堆无关角色匹出来
  /// (服务端那条也踩过,所以那边至今不回写 req.user_request)。
  String canvasBlock = '',
  List<Map<String, String>> history = const [],

  /// 本地的画师串库 / OC 库([libArtistsOf] / [libOcsOf] 认的形状)。只在本机用,不发出去。
  List<Map<String, dynamic>> webArtists = const [],
  List<Map<String, dynamic>> webOcs = const [],
  bool ocPlaceholders = false,

  /// 上一轮记下的沿用资源(画师串 / 占位符模式下的 OC)。本轮没点到的补进资料块,收尾时连同本轮命中的
  /// 一起并成新账本,随 [AgentResult.resources] 回去。
  Map<String, Map<String, String>> resources = const {},

  /// 设置里的「资料库范围」(`none` / `local` / `all`)。
  /// 预匹配和查库工具都吃这一项,两处必须同口径。
  String libraryScope = 'local',

  /// 用户选的模式(见 assistant_mode.dart),和预匹配判回来的一起挑段。
  List<String> chosenModes = const [],
  ThinkLevel think = ThinkLevel.auto,

  /// 逐字显示(助手设置里的开关)。关掉就是老样子:整段收完再一次出。
  bool stream = true,
  Duration timeout = const Duration(seconds: 120),

  /// 调试记录:系统提示、消息、每一跳的模型原话和工具结果都记进去。
  AgentTrace? trace,
}) async* {
  final client = http.Client();
  try {
    final artists = libArtistsOf(webArtists);
    final ocs = libOcsOf(webOcs);
    final remembered = healRememberedArtists(resources, artists);

    // 后端那两块彼此不相干,并着取 —— 串着取等于在第一次模型调用前白等两个往返。
    // 附图要缩的话也在这时候缩。
    final (toolsBlock, server, img) = await (
      _fetchToolsBlock(client, backendBase, sessionId),
      _fetchServerPrequery(
        client,
        backendBase,
        sessionId,
        text: userRequest,
        libraryScope: libraryScope,
      ),
      image == null ? Future<DirectImage?>.value() : prepareDirectImage(image),
    ).wait;
    final pre = buildLocalPrequery(
      text: userRequest,
      artists: artists,
      ocs: ocs,
      remembered: remembered,
      useLibrary: libraryScope != 'none',
      publicArtists: server.artists,
      publicOcs: server.ocs,
      roleBlock: server.roleBlock,
      ocPlaceholders: ocPlaceholders,
    );
    final tokens = pre.plan.tokens;
    final ocTokens = pre.ocPlan.tokens;
    String collapseResources(String value) =>
        collapseArtistStrings(collapseArtistStrings(value, tokens), ocTokens);
    // 判模式看这一轮发出去的全部文字:用户原话、画布、历史(「上一轮画过分格图」)。
    // 资料块不算 —— 画师串里带个 comic 不代表这轮在画漫画。
    final modes = detectPromptModes([
      userRequest,
      canvasBlock,
      for (final h in history) h['content'] ?? '',
    ]);
    final system =
        directSystemPrompt(
          rules: rules,
          modes: modes,
          chosen: chosenModes,
          outputFormat: outputFormat,
          toolsBlock: toolsBlock,
        ) +
        (ocPlaceholders
            ? '\n\n[OC 占位符模式]\n$kOcBlockNote。search_character 返回的 OC tags 也是占位符；不要猜测或展开其内容。'
            : '');
    trace
      ?..prequery = {
        'block': pre.block,
        'this_turn': pre.thisTurn,
        'modes': modes,
        'artist_placeholders': tokens,
        if (ocPlaceholders) 'oc_placeholders': ocTokens,
      }
      ..system = system;

    // 消息流:历史 + 本轮。工具结果以 user 文本回灌,与服务端那条同一种形状。
    // 用户那段 + 画布拼成一条 user 消息,资料块跟在后面。
    // 用户输入、画布和历史里认得出的完整资源折成占位符 —— 模型看到的「自己上次写的」就是占位符,
    // 不会照着抄完整串(服务端那条在 run_chat_with_retries 里做同一件事)。
    final msgs = <DirectMsg>[
      for (final h in history)
        (
          role: h['role'] ?? 'user',
          content: collapseResources(h['content'] ?? ''),
          image: null,
        ),
      (
        role: 'user',
        content: [
          ocPlaceholders ? collapseResources(userRequest) : userRequest,
          collapseResources(canvasBlock),
          pre.block,
        ].where((s) => s.isNotEmpty).join('\n\n'),
        image: img,
      ),
    ];

    trace?.messages = [
      for (final m in msgs)
        {
          'role': m.role,
          'content': m.content,
          if (m.image case final i?)
            'image': '<${i.mime} base64 ${i.data.length} 字符>',
        },
    ];

    // 每一跳的思考都留着:查资料那几跳里想的(「先查一下这个角色」)和最后一跳一样
    // 是这一轮怎么想出来的,只留最后一跳就看不出它为什么去查。
    final thoughts = <String>[];
    // 不限跳数(每跳 = 一次模型调用):模型不再调工具才收尾。原地打转的话只能靠
    // 用户点停止 —— 订阅一取消,下一次 yield 就退出循环,finally 照常关连接。
    while (true) {
      final hopStart = trace?.sinceStart() ?? 0;
      final buf = StringBuffer();
      final reason = StringBuffer();
      await for (final d in directModelStream(
        client,
        endpoint,
        system: system,
        msgs: msgs,
        think: think,
        stream: stream,
        timeout: timeout,
        out: buf,
        reasoning: reason,
      )) {
        yield d;
      }
      final raw = buf.toString();
      final hopThink = joinThoughts([
        reason.toString(),
        directStreamView(raw).think,
      ]);
      if (hopThink.isNotEmpty) thoughts.add(hopThink);
      if (raw.trim().isEmpty) throw BackendException('模型回了一段空的');
      final hopRec = <String, Object?>{
        't': hopStart,
        'ms': (trace?.sinceStart() ?? 0) - hopStart,
        'reply': raw,
        if (hopThink.isNotEmpty) 'reasoning': hopThink,
      };
      trace?.hops.add(hopRec);
      final calls = parseToolCalls(raw);
      if (calls.isEmpty) {
        final parsed = parseDirectReply(raw);
        final resolve = artistResolver(pre.plan, artists);
        if (libraryScope == 'all' && parsed.draw != null) {
          await _resolvePublicArtists(
            client,
            backendBase,
            sessionId,
            draw: parsed.draw!,
            resolve: resolve,
            plan: pre.plan,
          );
        }
        final draw = ocPlaceholders
            ? expandOcDraw(expandDraw(parsed.draw, resolve), pre.ocPlan)
            : expandDraw(parsed.draw, resolve);
        final reply = ocPlaceholders
            ? namesInOcReply(namesInReply(parsed.reply, resolve), pre.ocPlan)
            : namesInReply(parsed.reply, resolve);
        final ledger = mergeLedger(
          remembered,
          pre.thisTurn,
          draw,
          rememberOcs: ocPlaceholders,
        );
        trace?.event('final', {
          'reply': reply,
          'draw': parsed.draw,
          if (draw != parsed.draw) 'draw_expanded': draw,
          'resources': ledger,
        });
        yield AgentDone(
          _toResult(reply, draw, ledger, reasoning: thoughts.join('\n\n')),
        );
        return;
      }

      msgs.add((role: 'assistant', content: raw, image: null));
      hopRec['tool_calls'] = [
        for (final c in calls) {'name': c.name, 'arguments': c.args},
      ];
      final chunks = <String>[];
      for (final c in calls) {
        yield AgentToolCall(c.name, c.args);
        String summary;
        Object? result;
        try {
          result = await _runTool(
            client,
            backendBase,
            sessionId,
            c,
            artists: artists,
            ocs: ocs,
            libraryScope: libraryScope,
          );
          if (c.name == 'search_artist' || c.name == 'random_artist') {
            rememberToolArtists(pre.plan, result);
          }
          if (ocPlaceholders && c.name == 'search_character') {
            if (result is List) {
              for (final row in result) {
                if (row is Map && row['source'] == 'oc') {
                  final name = '${row['name'] ?? ''}'.trim();
                  final tags = '${row['tags'] ?? ''}'.trim();
                  if (name.isNotEmpty && tags.isNotEmpty) {
                    pre.thisTurn['oc']![name] = tags;
                  }
                }
              }
            }
            result = maskOcToolResults(result, pre.ocPlan);
          }
          summary = result is List ? '${result.length} 条' : '已返回';
        } catch (e) {
          result = null;
          summary = '$e';
        }
        yield AgentToolResult(c.name, summary);
        chunks.add(
          '[${c.name}] ${result == null ? "执行失败:$summary" : jsonEncode(result)}',
        );
      }
      hopRec['tool_results'] = chunks.join('\n\n');
      msgs.add((
        role: 'user',
        content:
            '[tool_result 共 ${calls.length} 条] 以下是你上一条回复里 tool_call 的执行结果。'
            '请基于结果给出**最终回复**(不要再重复调用同样的工具)。\n\n'
            '${chunks.join("\n\n")}',
        image: null,
      ));
    }
  } finally {
    client.close();
  }
}

AgentResult _toResult(
  String reply,
  Map<String, dynamic>? draw,
  Map<String, Map<String, String>> resources, {
  String reasoning = '',
}) {
  final d = draw ?? const <String, dynamic>{};
  return AgentResult(
    replyText: reply.isNotEmpty ? reply : '本喵在喵~',
    reasoning: reasoning,
    positive: d['positive']?.toString() ?? '',
    negative: d['negative']?.toString() ?? '',
    characters: [
      for (final c in (d['characters'] as List? ?? const []))
        if (c is Map<String, dynamic>) AgentCharacter.fromJson(c),
    ],
    // 并好的账本原样带出去。**不能回空** —— 调用方是拿最新那条 AI
    // 消息的账本发下一轮的,回空等于把之前记着的画风冲掉。
    resources: resources,
  );
}

/// 服务端那份预匹配:[角色候选](角色索引在服务端),选了「+ 公共库」时再加上公共库
/// 命中的画师串 / OC。
///
/// **只发这句话和资料库范围** —— 本地库、账本、画布一样不带,本地那份在
/// [buildLocalPrequery] 里做。「不使用」时服务端什么都不给,不打。
/// 拿不到就空着走 —— 没有候选模型还能靠工具自己查,为此整轮失败不划算。
Future<
  ({String roleBlock, Map<String, String> artists, Map<String, String> ocs})
>
_fetchServerPrequery(
  http.Client c,
  String base,
  String sessionId, {
  required String text,
  required String libraryScope,
}) async {
  const empty = (
    roleBlock: '',
    artists: <String, String>{},
    ocs: <String, String>{},
  );
  if (base.isEmpty || libraryScope == 'none' || text.trim().isEmpty) {
    return empty;
  }
  try {
    final r = await c
        .post(
          Uri.parse('$base/api/agent/prequery'),
          headers: {'Content-Type': 'application/json', ..._auth(sessionId)},
          body: jsonEncode({
            'user_request': text,
            'library_scope': libraryScope,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return empty;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) return empty;
    // 本地库没发过去,服务端命中的画师串 / OC 只可能来自公共库
    final hits = decodeResources(j['this_turn']);
    return (
      roleBlock: pickBlock(j['block']?.toString() ?? '', kRoleBlock),
      artists: hits['artist'] ?? const <String, String>{},
      ocs: hits['oc'] ?? const <String, String>{},
    );
  } catch (_) {
    return empty;
  }
}

/// 画面里还有认不出的占位符(工具在上一轮查到的公共库画师)→ 按编号去公共库查一次,
/// 查到的记进映射。只在「+ 公共库」时调,发过去的只有编号。
Future<void> _resolvePublicArtists(
  http.Client c,
  String base,
  String sessionId, {
  required Map<String, dynamic> draw,
  required ArtistResolver resolve,
  required ArtistPlan plan,
}) async {
  final missing = {
    for (final t in drawTexts(draw))
      for (final m in artistTokenRe.allMatches(t))
        if (resolve(m[1]!) == null) m[1]!,
  };
  if (missing.isEmpty) return;
  try {
    rememberToolArtists(
      plan,
      await _serverTool(c, base, sessionId, (
        name: 'search_artist',
        args: {'artist_ids': missing.toList()},
      ), 'all'),
    );
  } catch (_) {
    // 查不到就算了:认不出的占位符还原时会被删掉
  }
}

/// 「可用工具」块。拿不到就返回空串 —— 没有工具照样能出词,只是查不了资料;
/// 为此整轮失败不划算。
Future<String> _fetchToolsBlock(
  http.Client c,
  String base,
  String sessionId,
) async {
  if (base.isEmpty) return '';
  try {
    final r = await c
        .get(Uri.parse('$base/api/agent/tools'), headers: _auth(sessionId))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return '';
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return (j is Map ? j['block']?.toString() : null) ?? '';
  } catch (_) {
    return '';
  }
}

/// 执行一次工具调用。
///
/// 查本地库的(search_artist、random_artist,search_character 的 OC 那半)在本机做,库不出本机;
/// 服务端自己的数据 —— 角色索引、tag 百科、选了「+ 公共库」时的公共库 —— 去后端查,
/// 发过去的只有工具参数。两边都有的,本地的排前面。
Future<Object?> _runTool(
  http.Client c,
  String base,
  String sessionId,
  ({String name, Map<String, dynamic> args}) call, {
  required List<LibArtist> artists,
  required List<LibOc> ocs,
  required String libraryScope,
}) async {
  final mine = libraryScope != 'none';
  final withPublic = libraryScope == 'all';

  // 本地已经查到东西时,后端那半挂了不该让整个工具失败
  Future<List<Object?>> remote({required bool quiet}) async {
    try {
      final r = await _serverTool(c, base, sessionId, call, libraryScope);
      return r is List ? r : const [];
    } catch (_) {
      if (quiet) return const [];
      rethrow;
    }
  }

  switch (call.name) {
    case 'search_artist':
      final local = mine
          ? searchLocalArtists(artists, call.args)
          : const <Map<String, dynamic>>[];
      if (!withPublic) return local;
      final seen = {
        for (final a in local) ...[
          '${a['id']}'.toUpperCase(),
          '${a['name']}'.toUpperCase(),
        ],
      };
      return [
        ...local,
        for (final a in await remote(quiet: local.isNotEmpty))
          if (a is Map &&
              !seen.contains('${a['id']}'.toUpperCase()) &&
              !seen.contains('${a['name']}'.toUpperCase()))
            a,
      ];
    case 'random_artist':
      final count = intArg(call.args['count'], 1).clamp(1, 5);
      final pool = <Object?>[
        if (mine)
          for (final a in artists) artistToolEntry(a),
        if (withPublic) ...await remote(quiet: mine && artists.isNotEmpty),
      ]..shuffle();
      return pool.take(count).toList();
    case 'search_character':
      final args = call.args;
      if ('${args['query'] ?? ''}'.trim().isEmpty &&
          '${args['origin'] ?? ''}'.trim().isEmpty) {
        return const <Object?>[];
      }
      final local = mine
          ? searchLocalOcs(ocs, args)
          : const <Map<String, dynamic>>[];
      final limit = intArg(args['limit'], 30).clamp(1, 200);
      return [
        ...local,
        ...await remote(quiet: local.isNotEmpty),
      ].take(limit).toList();
    default:
      return _serverTool(c, base, sessionId, call, libraryScope);
  }
}

/// 后端代调一个工具。**不带本地库** —— 服务端拿到的只有工具参数和资料库范围。
Future<Object?> _serverTool(
  http.Client c,
  String base,
  String sessionId,
  ({String name, Map<String, dynamic> args}) call,
  String libraryScope,
) async {
  if (base.isEmpty) throw BackendException('没有后端地址,查不了资料');
  final r = await c
      .post(
        Uri.parse('$base/api/agent/tools/call'),
        headers: {'Content-Type': 'application/json', ..._auth(sessionId)},
        body: jsonEncode({
          'name': call.name,
          'arguments': call.args,
          'library_scope': libraryScope,
        }),
      )
      .timeout(const Duration(seconds: 30));
  final j = jsonDecode(utf8.decode(r.bodyBytes));
  if (r.statusCode < 200 || r.statusCode >= 300) {
    final detail =
        (j is Map ? j['detail']?.toString() : null) ?? '${r.statusCode}';
    throw BackendException(detail);
  }
  return j is Map ? j['result'] : null;
}

/// 有 Bot 授权才带会话;没有就匿名打,后端对匿名调用不给公共库。
Map<String, String> _auth(String sessionId) =>
    sessionId.isEmpty ? const {} : {'Authorization': 'Bearer $sessionId'};

/// 两帧之间至少隔这么久。快的模型一秒吐几十个 token,一个 token 推一帧等于每秒
/// 几十次整块重建(气泡里是按围栏分块的富文本);60ms 一帧看着仍然是连续在写。
const _liveFrameMs = 60;

/// 打一次模型,边收边吐。
///
/// 每帧 [AgentDelta] 带的是**到此刻为止**的正文与思考(整块替换,理由见那边),
/// 整段原文写进 [out] —— 这条链路的产出是「一段回复 + 一个围栏」,围栏收完才解析
/// 得了,所以**流只管显示**,解析照旧在 [parseDirectReply] / [parseToolCalls]。
///
/// [timeout] 不再是整轮上限,而是「等响应头」和「两帧之间」各自的静默上限:
/// 长回复本来就写得过一分钟,按整轮掐必然误杀;而只要还在吐字就说明活着。
///
/// 中转不认流式(回的不是 `text/event-stream`)时,收完整个 body 按老路解析,
/// 只是没有逐字效果 —— 不能因为这个就让人用不了。
Stream<AgentDelta> directModelStream(
  http.Client c,
  CustomEndpoint e, {
  required String system,
  required List<DirectMsg> msgs,
  required ThinkLevel think,
  required Duration timeout,
  required StringBuffer out,

  /// 模型原生的思考(不含正文里的 `<Think>` 段 —— 那段在 [out] 里,调用方自己切)。
  /// 不传就不收。
  StringBuffer? reasoning,

  /// 关掉就是老样子:一个 POST 收完整段,一帧都不推。
  bool stream = true,
}) async* {
  // 路径可配(中转改路径是常事),Gemini 那条还把模型名写在路径里、开流还要换方法名
  // —— 都由 CustomEndpoint 处理,这儿不再各拼各的。
  final uri = stream ? e.chatStreamUri : e.chatUri;
  final (headers, body) = directRequest(
    e,
    system: system,
    msgs: msgs,
    think: think,
    stream: stream,
  );
  Future<http.StreamedResponse> send(Map<String, dynamic> body) async {
    final req = http.Request('POST', uri)
      ..headers.addAll(
        e.withHeaders({
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
          ...headers,
        }),
      )
      ..bodyBytes = utf8.encode(jsonEncode(body));
    try {
      return await c.send(req).timeout(timeout);
    } on TimeoutException {
      throw BackendException('模型没在时限内回复');
    } catch (_) {
      throw BackendException('连不上 ${uri.host}');
    }
  }

  var resp = await send(body);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    final raw = await resp.stream.bytesToString().timeout(timeout);
    final msg = _errorOf(_tryJson(raw), resp.statusCode);
    // OpenAI 的思考摘要要组织做过认证才给,没认证的整条请求 400。为了看思考
    // 把人整个挡在外面不值:去掉摘要再发一次,照常出词,只是没有思考可看。
    final retry = resp.statusCode == 400
        ? withoutReasoningSummary(body, msg)
        : null;
    if (retry == null) throw BackendException(msg);
    resp = await send(retry);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final raw = await resp.stream.bytesToString().timeout(timeout);
      throw BackendException(_errorOf(_tryJson(raw), resp.statusCode));
    }
  }
  final reason = reasoning ?? StringBuffer();
  final Stream<String> lines;
  if (stream &&
      (resp.headers['content-type'] ?? '').toLowerCase().contains(
        'event-stream',
      )) {
    lines = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(
          timeout,
          onTimeout: (sink) => sink.addError(BackendException('模型写到一半没声了')),
        );
  } else {
    final raw = await resp.stream.bytesToString().timeout(timeout);
    final j = _tryJson(raw);
    final text = extractReplyText(e.format, j);
    if (text.isNotEmpty || !stream || !raw.contains('data:')) {
      out.write(text); // 空的话由调用方报「模型回了一段空的」
      reason.write(extractReplyReasoning(e.format, j));
      // 关着开关时一帧都不推:气泡就该老老实实转圈到出结果
      if (text.isNotEmpty && stream) yield _liveDelta(out, reason);
      return;
    }
    // 类型写着 json、身子却是一串 SSE 帧 —— 有的中转就这德行。按帧收,
    // 只是整段一起到,没有逐字效果。
    lines = Stream.fromIterable(const LineSplitter().convert(raw));
  }

  var lastFrame = 0;
  await for (final line in lines) {
    // `event:` 行与 `:` 心跳不看:各家的 data 自带类型,光看 data 就够
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') continue;
    final frame = _tryJson(data);
    // Claude / Responses 的报错是流中间的一帧,不是 HTTP 状态码
    if (frame is Map && frame['type'] == 'error') {
      throw BackendException(_errorOf(frame, resp.statusCode));
    }
    if (frame is Map && frame['type'] == 'response.failed') {
      throw BackendException(_errorOf(frame['response'], resp.statusCode));
    }
    final d = directDelta(e.format, frame);
    if (d.text.isEmpty && d.reasoning.isEmpty) continue;
    out.write(d.text);
    reason.write(d.reasoning);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - lastFrame < _liveFrameMs) continue;
    lastFrame = now;
    yield _liveDelta(out, reason);
  }
  // 收尾补一帧:最后几个字多半还卡在上面那道攒帧里
  yield _liveDelta(out, reason);
}

/// 请求被拒是因为要了思考摘要(OpenAI 没做组织认证)→ 去掉摘要的那份请求体;
/// 别的原因返回 null,照常报错。
///
/// 只认 Responses 那种 `reasoning.summary`;判据是报错原话里提没提摘要 / 认证 ——
/// OpenAI 没给专门的错误码,而只凭 400 就重发会把别的错(模型名写错)掩盖成一次白跑。
Map<String, dynamic>? withoutReasoningSummary(
  Map<String, dynamic> body,
  String error,
) {
  final r = body['reasoning'];
  if (r is! Map || !r.containsKey('summary')) return null;
  final e = error.toLowerCase();
  if (!e.contains('summar') && !e.contains('verif')) return null;
  return {
    ...body,
    'reasoning': {...r}..remove('summary'),
  };
}

AgentDelta _liveDelta(StringBuffer raw, StringBuffer reason) {
  final v = directStreamView(raw.toString());
  return AgentDelta(
    text: v.body,
    reasoning: joinThoughts([reason.toString(), v.think]),
  );
}

/// 几段思考拼成一段:各自去掉首尾空白,空的不要。
String joinThoughts(List<String> parts) => [
  for (final p in parts)
    if (p.trim().isNotEmpty) p.trim(),
].join('\n');

Object? _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null; // 不是 JSON:当没有错误体,按状态码报
  }
}

/// 流式响应的一帧 → 这一帧新增的字。各家形状各不相同,抽出来单测 —— 认错字段的
/// 表现是「一路空白、最后整段蹦出来」,跟模型自己慢分不出来。
///
/// 思考在各家都是正文之外的另一个字段,所以分两路回:
///   · OpenAI 兼容:见 [_openaiMessage](各家推理模型、中转、本地推理的几种写法)
///   · Responses:`response.reasoning_summary_text.delta`(官方推理模型的摘要)、
///     `response.reasoning_text.delta`(gpt-oss 这类开源模型的原文)
///   · Gemini:`parts[]` 里 `thought` 为真的那几段
///   · Claude:`thinking_delta`
({String text, String reasoning}) directDelta(
  AgentApiFormat format,
  Object? frame,
) {
  const none = (text: '', reasoning: '');
  if (frame is! Map) return none;
  switch (format) {
    case AgentApiFormat.openai:
      final choices = frame['choices'];
      if (choices is! List || choices.isEmpty) return none;
      final first = choices.first;
      if (first is! Map) return none;
      final d = first['delta'];
      // 老式补全接口没有 delta,只有 text
      if (d is! Map) {
        return (
          text: first['text'] is String ? first['text'] as String : '',
          reasoning: '',
        );
      }
      return _openaiMessage(d);
    case AgentApiFormat.responses:
      final delta = frame['delta'] is String ? frame['delta'] as String : '';
      return switch (frame['type']) {
        'response.output_text.delta' => (text: delta, reasoning: ''),
        'response.reasoning_summary_text.delta' ||
        'response.reasoning_text.delta' => (text: '', reasoning: delta),
        // 摘要是分段写的(每段一个小标题),段与段之间空一行,不然全挤成一坨
        'response.reasoning_summary_part.added'
            when (frame['summary_index'] as num? ?? 0) > 0 =>
          (text: '', reasoning: '\n\n'),
        _ => none,
      };
    case AgentApiFormat.google:
      return _geminiParts(frame);
    case AgentApiFormat.anthropic:
      final d = frame['delta'];
      if (d is! Map) return none;
      return switch (d['type']) {
        'text_delta' => (
          text: d['text'] is String ? d['text'] as String : '',
          reasoning: '',
        ),
        'thinking_delta' => (
          text: '',
          reasoning: d['thinking'] is String ? d['thinking'] as String : '',
        ),
        // message_delta(停止原因)这类也带 delta,但不带字
        _ => none,
      };
  }
}

/// OpenAI 兼容的一条消息(非流式的 `message` / 流式的 `delta`)→ 正文与思考。
///
/// 「OpenAI 兼容」只兼容到正文为止,思考各家各写各的:
///   · `reasoning_content`:DeepSeek、通义、智谱、豆包、Kimi、硅基流动、LM Studio、老版 vLLM;
///     多数中转把 Claude / Gemini 的思考也转成这个
///   · `reasoning`:OpenRouter、Ollama、新版 vLLM
///   · `reasoning_details[]`:OpenRouter 的另一份,有的模型 `reasoning` 空着、
///     思考只在这里(原文 `text` 或摘要 `summary`;加密的那种没字可看)
///   · `content` 是分段数组、思考段 `type: thinking`:Mistral 的推理模型
/// 写在正文里的 `<think>` 那一派(MiniMax、部分本地模型)不在这里,留在正文里由
/// [directStreamView] / [parseDirectReply] 切。
({String text, String reasoning}) _openaiMessage(Map m) {
  final text = StringBuffer();
  final think = StringBuffer();
  final c = m['content'];
  if (c is String) {
    text.write(c);
  } else if (c is List) {
    for (final p in c) {
      if (p is! Map) continue;
      if (p['type'] == 'thinking') {
        think.write(_flatText(p['thinking']));
      } else if (p['text'] is String) {
        text.write(p['text']);
      }
    }
  }
  final r = m['reasoning_content'] ?? m['reasoning'];
  if (r is String && r.isNotEmpty) {
    think.write(r);
  } else if (m['reasoning_details'] case final List details) {
    for (final d in details) {
      if (d is! Map) continue;
      final t = d['text'] ?? d['summary'];
      if (t is String) think.write(t);
    }
  }
  return (text: text.toString(), reasoning: think.toString());
}

/// 字符串原样;分段数组(`[{type: text, text}]`)拼起来。
String _flatText(Object? v) => switch (v) {
  final String s => s,
  final List l => [
    for (final p in l)
      if (p is String)
        p
      else if (p is Map && p['text'] is String)
        p['text'] as String,
  ].join(),
  _ => '',
};

/// Gemini 的一个候选 → 正文与思考(`thought: true` 的那几段)。流式的每一帧和
/// 非流式的整包是同一个形状。
({String text, String reasoning}) _geminiParts(Map body) {
  const none = (text: '', reasoning: '');
  final cands = body['candidates'];
  if (cands is! List || cands.isEmpty) return none;
  final first = cands.first;
  if (first is! Map) return none;
  final parts = (first['content'] as Map?)?['parts'];
  if (parts is! List) return none;
  final text = StringBuffer();
  final think = StringBuffer();
  for (final p in parts) {
    if (p is! Map || p['text'] is! String) continue;
    (p['thought'] == true ? think : text).write(p['text']);
  }
  return (text: text.toString(), reasoning: think.toString());
}

/// 流到一半的原文 → 气泡里该显示的两块。
///
/// 纯函数,每帧拿全量原文重算:`</Think>` 收尾那一刻正文会整段挪位,增量式拼接
/// 得为这一下单独留一套回退。
///
/// 正文到第一个 ```tool_call / ```nai_draw 围栏为止 —— 围栏里是给机器看的 JSON,
/// 而且收完才解析得了。普通的 ``` 代码块照留(回复里列 tag 会用到)。
/// `<Think>` 段(含还没收尾的)整段划到思考那边。
({String body, String think}) directStreamView(String raw) {
  final think = <String>[];
  final body = StringBuffer();
  var pos = 0;
  for (final m in _thinkOpen.allMatches(raw)) {
    if (m.start < pos) continue; // 上一段 <Think> 内部的,不重复处理
    body.write(raw.substring(pos, m.start));
    // 收尾标签得和开头同名:`<think>` 里提到一句 `</thought>` 不算收尾
    final close = RegExp(
      '</${m[1]}>',
      caseSensitive: false,
    ).firstMatch(raw.substring(m.end));
    if (close == null) {
      think.add(raw.substring(m.end)); // 还没收尾:后面全算思考
      pos = raw.length;
      break;
    }
    think.add(raw.substring(m.end, m.end + close.start));
    pos = m.end + close.end;
  }
  if (pos < raw.length) body.write(raw.substring(pos));
  var text = body.toString();
  final fence = _liveFenceOpen.firstMatch(text);
  if (fence != null) text = text.substring(0, fence.start);
  return (
    body: text.replaceFirst(_liveTail, '').trim(),
    think: think.join('\n').trim(),
  );
}

/// 一次模型调用的请求头与请求体。各家的形状各不相同,抽出来单测 ——
/// 附图字段写错的表现是「模型说没看到图」,和它自己看走眼分不出来。
///
/// 带图的那条 content 从字符串换成分段数组,**图在前、字在后**
/// (Claude 与 Gemini 的文档都建议单图时这么摆,OpenAI 不挑)。
(Map<String, String>, Map<String, dynamic>) directRequest(
  CustomEndpoint e, {
  required String system,
  required List<DirectMsg> msgs,
  required ThinkLevel think,

  /// 开流式。Gemini 不在体里开 —— 它换的是路径,见 [CustomEndpoint.chatStreamUri]。
  bool stream = false,
}) {
  final key = e.apiKey.trim();
  final thinking = thinkFields(
    e.format,
    think,
    model: e.model,
    host: e.chatUri.host,
    stream: stream,
  );
  return switch (e.format) {
    AgentApiFormat.openai => (
      {'Authorization': 'Bearer $key'},
      {
        'model': e.model,
        'messages': [
          {'role': 'system', 'content': system},
          for (final m in msgs)
            {
              'role': m.role,
              'content': switch (m.image) {
                final i? => [
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:${i.mime};base64,${i.data}'},
                  },
                  if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
                ],
                null => m.content,
              },
            },
        ],
        if (stream) 'stream': true,
        ...thinking,
      },
    ),
    AgentApiFormat.responses => (
      {'Authorization': 'Bearer $key'},
      {
        'model': e.model,
        'instructions': system,
        'input': [
          for (final m in msgs)
            {
              'role': m.role,
              'content': switch (m.image) {
                final i? => [
                  {
                    'type': 'input_image',
                    'image_url': 'data:${i.mime};base64,${i.data}',
                  },
                  if (m.content.isNotEmpty)
                    {'type': 'input_text', 'text': m.content},
                ],
                null => m.content,
              },
            },
        ],
        if (stream) 'stream': true,
        // 历史每轮都是 app 自己带着发的,用不着服务端再替你存一份对话
        'store': false,
        ...thinking,
      },
    ),
    AgentApiFormat.google => (
      {'x-goog-api-key': key},
      {
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
        'contents': [
          for (final m in msgs)
            {
              // Gemini 只认 user / model 两种
              'role': m.role == 'assistant' ? 'model' : 'user',
              'parts': [
                if (m.image case final i?)
                  {
                    'inlineData': {'mimeType': i.mime, 'data': i.data},
                  },
                if (m.image == null || m.content.isNotEmpty)
                  {'text': m.content},
              ],
            },
        ],
        ...thinking,
      },
    ),
    AgentApiFormat.anthropic => (
      {'x-api-key': key, 'anthropic-version': '2023-06-01'},
      {
        'model': e.model,
        // Anthropic 必填,且没有"不限"这一档。老模型开了思考还得**大于**思考预算,
        // 否则整条请求会被拒:那笔预算是从 max_tokens 里切出去的。新模型(自适应思考)
        // 想多少由它自己定,同样从这里面扣,给少了会想到一半被截断、正文一个字没写。
        'max_tokens': _claudeLegacy.hasMatch(e.model)
            ? 4096 + _anthropicBudget(think)
            : 16000,
        'system': system,
        'messages': [
          for (final m in msgs)
            {
              'role': m.role,
              'content': switch (m.image) {
                final i? => [
                  {
                    'type': 'image',
                    'source': {
                      'type': 'base64',
                      'media_type': i.mime,
                      'data': i.data,
                    },
                  },
                  if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
                ],
                null => m.content,
              },
            },
        ],
        if (stream) 'stream': true,
        ...thinking,
      },
    ),
  };
}

/// Anthropic 老模型的思考预算(token)。0 = 不开。下限是它自己规定的 1024。
int _anthropicBudget(ThinkLevel l) => switch (l) {
  ThinkLevel.auto || ThinkLevel.off => 0,
  ThinkLevel.low => 1024,
  ThinkLevel.medium => 4096,
  ThinkLevel.high => 8192,
  ThinkLevel.ultra => 16384,
};

/// Gemini 的思考预算(token)。原生接口和 OpenAI 兼容口、通义都按这张表。
int _thinkBudget(ThinkLevel l) => switch (l) {
  ThinkLevel.off => 0,
  ThinkLevel.low => 1024,
  ThinkLevel.high => 16384,
  ThinkLevel.ultra => 24576,
  _ => 8192,
};

/// 还在用固定思考预算(`budget_tokens`)的 Claude:3.x、4、4.1、4.5。
///
/// 4.6 起换成了自适应思考,4.7 起 `budget_tokens` 直接 400 —— 按模型名分两路。
/// 认不出的名字(中转起的别名)按新的走:老模型在下线,新模型越来越多。
/// 版本号可能写成 `4-5` 也可能写成 `4.5`(OpenRouter),后面可能跟日期。
final _claudeLegacy = RegExp(
  r'claude-3|(?:opus|sonnet|haiku)-4(?:[.-][015])?(?=$|-20\d{6}|[^0-9.-]|[.-][^0-9])',
  caseSensitive: false,
);

/// 思考关不掉、默认就在想的 Claude(5 代起,以及 Fable / Mythos)。
///
/// 这几个模型默认**不回思考的字**(`display` 默认 `omitted`,思考块是空串),
/// 要显示得明着要 `summarized`;想关也关不掉,`disabled` 是 400,只能把力度调低。
final _claudeAlwaysThinks = RegExp(
  r'(?:opus|sonnet|haiku)-[5-9]|fable|mythos',
  caseSensitive: false,
);

/// 会思考的 Gemini(2.5 起)。只有这些认 `includeThoughts`。
final _geminiThinks = RegExp(r'gemini-(?:2\.5|[3-9])', caseSensitive: false);

/// 有推理能力的 OpenAI 模型:只有这些认 `reasoning`,别的(4o、4.1)带了就 400。
/// `gpt-5-chat` 那几个名字里带 5 却是不推理的聊天模型。
final _openaiReasons = RegExp(
  r'(?:^|/)(?:o\d|gpt-5(?!.*chat)|gpt-oss|codex)',
  caseSensitive: false,
);

/// [host] 是 [domain] 本身或它的子域。
bool _hostIs(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// 思考等级 → 请求体里的那几个字段。
///
/// 各家的旋钮完全不是一回事:OpenAI 给的是档位字符串,Gemini 要 token 预算,
/// Claude 新老模型两套,国内几家还各有一个开关。
///
/// [ThinkLevel.auto] 的意思是「思考按模型自己的默认」—— **不替用户开也不替用户关**。
/// 但「默认在想、默认不给看」的那几家(新 Claude、Gemini、OpenAI 推理模型)会补上
/// 「把思考给我看」的那个字段,只改看不看得见,不改想不想、想多深。
///
/// 中转不认这些字段时通常直接忽略,所以发了也不至于把请求打死;
/// 只对认得出的服务商(按 [host])发它家的私有字段 —— OpenAI 官方见到不认识的字段是 400。
Map<String, dynamic> thinkFields(
  AgentApiFormat format,
  ThinkLevel level, {
  String model = '',
  String host = '',

  /// 通义的开源模型开着思考时**只能流式**,非流式请求带 `enable_thinking: true` 直接 400。
  bool stream = true,
}) => switch (format) {
  AgentApiFormat.openai => _openaiThink(
    level,
    model: model,
    host: host.toLowerCase(),
    stream: stream,
  ),
  AgentApiFormat.responses => _responsesThink(level, model),
  AgentApiFormat.google => _geminiThink(level, model),
  AgentApiFormat.anthropic => _claudeThink(level, model),
};

Map<String, dynamic> _openaiThink(
  ThinkLevel level, {
  required String model,
  required String host,
  required bool stream,
}) {
  // Gemini 的 OpenAI 兼容口:思考要在 extra_body 里另开,开了才会把思考
  // 包成 `<thought>` 写进正文;`reasoning_effort` 和预算两个只能给一个。
  if (_hostIs(host, 'generativelanguage.googleapis.com')) {
    if (level == ThinkLevel.auto && !_geminiThinks.hasMatch(model)) {
      return const {};
    }
    return {
      'extra_body': {
        'google': {
          'thinking_config': {
            if (level != ThinkLevel.auto)
              'thinking_budget': _thinkBudget(level),
            if (level != ThinkLevel.off) 'include_thoughts': true,
          },
        },
      },
    };
  }
  if (level == ThinkLevel.auto) return const {};
  final on = level != ThinkLevel.off;
  return {
    'reasoning_effort': switch (level) {
      // OpenAI 两头都封顶:没有「关」,minimal 是最低;也没有「超高」,
      // high 是最高 —— 所以这两档各自撞在端点上,不是写漏了。
      ThinkLevel.off => 'minimal',
      ThinkLevel.low => 'low',
      ThinkLevel.high || ThinkLevel.ultra => 'high',
      _ => 'medium',
    },
    // 通义:思考靠 enable_thinking 开关,不认 reasoning_effort
    if (host.startsWith('dashscope') && _hostIs(host, 'aliyuncs.com'))
      if (!on)
        'enable_thinking': false
      else if (stream) ...{
        'enable_thinking': true,
        'thinking_budget': _thinkBudget(level),
      },
    // 智谱 / 豆包:thinking.type 开关
    if (_hostIs(host, 'bigmodel.cn') ||
        _hostIs(host, 'z.ai') ||
        _hostIs(host, 'volces.com'))
      'thinking': {'type': on ? 'enabled' : 'disabled'},
  };
}

Map<String, dynamic> _responsesThink(ThinkLevel level, String model) =>
    switch (level) {
      // 摘要是官方推理模型唯一能看的思考,不要就一个字都没有。
      // 没认证的组织要了会被拒,那时去掉摘要重发(见 withoutReasoningSummary)。
      ThinkLevel.auto =>
        _openaiReasons.hasMatch(model)
            ? {
                'reasoning': {'summary': 'auto'},
              }
            : const {},
      ThinkLevel.off => {
        'reasoning': {'effort': 'minimal'},
      },
      _ => {
        'reasoning': {
          'effort': switch (level) {
            ThinkLevel.low => 'low',
            ThinkLevel.medium => 'medium',
            _ => 'high',
          },
          'summary': 'auto',
        },
      },
    };

Map<String, dynamic> _geminiThink(ThinkLevel level, String model) {
  // 不带 includeThoughts 时 Gemini 照想不误,只是一个字都不回
  if (level == ThinkLevel.auto) {
    return _geminiThinks.hasMatch(model)
        ? {
            'generationConfig': {
              'thinkingConfig': {'includeThoughts': true},
            },
          }
        : const {};
  }
  return {
    'generationConfig': {
      'thinkingConfig': {
        'thinkingBudget': _thinkBudget(level),
        if (level != ThinkLevel.off) 'includeThoughts': true,
      },
    },
  };
}

Map<String, dynamic> _claudeThink(ThinkLevel level, String model) {
  if (_claudeLegacy.hasMatch(model)) {
    final budget = _anthropicBudget(level);
    // 「关」「自动」在老模型上就是不带 thinking 字段(它们默认不想)
    if (budget == 0) return const {};
    return {
      'thinking': {'type': 'enabled', 'budget_tokens': budget},
    };
  }
  const adaptive = {'type': 'adaptive', 'display': 'summarized'};
  final alwaysOn = _claudeAlwaysThinks.hasMatch(model);
  return switch (level) {
    // 4.6 ~ 4.8 默认不想,自动就不替它开;5 代默认在想,补上「给我看」
    ThinkLevel.auto => alwaysOn ? const {'thinking': adaptive} : const {},
    // 4.6 ~ 4.8 不带 thinking 就是不想;5 代关不掉(disabled 是 400),压到最低力度
    ThinkLevel.off =>
      alwaysOn
          ? const {
              'output_config': {'effort': 'low'},
            }
          : const {},
    _ => {
      'thinking': adaptive,
      'output_config': {
        'effort': switch (level) {
          ThinkLevel.low => 'low',
          ThinkLevel.medium => 'medium',
          ThinkLevel.high => 'high',
          _ => 'max',
        },
      },
    },
  };
}

/// 各家的响应 → 正文。认错字段的表现是「模型回了一段空的」,和真的空回
/// 长得一样,所以抽出来单测。思考不算正文,见 [extractReplyReasoning]。
String extractReplyText(AgentApiFormat format, Object? body) {
  if (body is! Map) return '';
  switch (format) {
    case AgentApiFormat.openai:
      final first = _firstChoice(body);
      if (first == null) return '';
      final msg = first['message'];
      if (msg is Map) return _openaiMessage(msg).text;
      return first['text']?.toString() ?? '';
    case AgentApiFormat.responses:
      final text = _responsesOutput(body, 'message', 'output_text');
      // 有的中转在顶上多给一个拼好的 output_text(官方 SDK 才有的便利字段)
      return text.isNotEmpty ? text : (body['output_text']?.toString() ?? '');
    case AgentApiFormat.google:
      return _geminiParts(body).text;
    case AgentApiFormat.anthropic:
      final content = body['content'];
      if (content is! List) return '';
      return [
        for (final p in content)
          if (p is Map && p['type'] == 'text') p['text']?.toString() ?? '',
      ].join();
  }
}

/// 各家的响应 → 模型原生的思考(非流式那条)。没有就是空串。
/// 写在正文里的 `<Think>` 段不在这里,见 [directStreamView]。
String extractReplyReasoning(AgentApiFormat format, Object? body) {
  if (body is! Map) return '';
  switch (format) {
    case AgentApiFormat.openai:
      final msg = _firstChoice(body)?['message'];
      return msg is Map ? _openaiMessage(msg).reasoning : '';
    case AgentApiFormat.responses:
      return joinThoughts([
        _responsesOutput(body, 'reasoning', 'summary_text', field: 'summary'),
        _responsesOutput(body, 'reasoning', 'reasoning_text'),
      ]);
    case AgentApiFormat.google:
      return _geminiParts(body).reasoning;
    case AgentApiFormat.anthropic:
      final content = body['content'];
      if (content is! List) return '';
      return joinThoughts([
        for (final p in content)
          if (p is Map && p['type'] == 'thinking') '${p['thinking'] ?? ''}',
      ]);
  }
}

Map? _firstChoice(Map body) {
  final choices = body['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final first = choices.first;
  return first is Map ? first : null;
}

/// Responses 的 `output[]` 里 [itemType] 那几项的 [field] 下 [partType] 那几段文字。
/// 正文在 message 的 content 里,思考摘要在 reasoning 的 summary 里;
/// 多段之间空一行(摘要每段一个小标题)。
String _responsesOutput(
  Map body,
  String itemType,
  String partType, {
  String field = 'content',
}) {
  final output = body['output'];
  if (output is! List) return '';
  final parts = <String>[];
  for (final item in output) {
    if (item is! Map || item['type'] != itemType) continue;
    final list = item[field];
    if (list is! List) continue;
    for (final p in list) {
      if (p is Map && p['type'] == partType && p['text'] is String) {
        parts.add(p['text'] as String);
      }
    }
  }
  return parts.join(itemType == 'reasoning' ? '\n\n' : '');
}

/// 错误体 → 给用户看的一句话。三家都把话装在 `error` 里,但形状不同。
String _errorOf(Object? body, int status) {
  if (body is Map) {
    final err = body['error'];
    if (err is Map) {
      final m = err['message']?.toString();
      if (m != null && m.isNotEmpty) return m;
    }
    if (err is String && err.isNotEmpty) return err;
    final m = body['message']?.toString();
    if (m != null && m.isNotEmpty) return m;
  }
  return '模型返回 $status';
}
