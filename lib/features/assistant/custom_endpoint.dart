/// 自定义 AI 接口:用户自己填的大模型地址,助手可以不走 Plana 后端直连它。
///
/// **存在加密存储里**,因为条目带 API Key —— 与 NAI 令牌同一条规矩
/// (见 `secure_storage.dart`:读写点一律走共享的那份配置,别自建)。
///
/// 直连那条用的是**规则主体**(与服务端那条同一份,见 `preset_rules.dart`),只是不套
/// 服务端的外壳;查角色、画风这些**工具仍然走后端**(`/api/agent/tools/call`),
/// 与 tag 补全同一个路子。没有的是降级阶梯、拒绝重掷、tag 哨兵 —— 跑失败就是失败。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/auth/secure_storage.dart';

const _key = 'assistant_endpoints';

/// 接口的报文格式。各家的鉴权头、请求体、模型列表路径都不一样。
///
/// 落盘存 `name`,插档不串位。
enum AgentApiFormat {
  /// OpenAI 兼容(`/chat/completions`,`Authorization: Bearer`)。
  /// 绝大多数第三方中转、本地推理都是这个。
  openai,

  /// OpenAI Responses(`/responses`,鉴权同上)。
  ///
  /// OpenAI 官方的推理模型(o 系、GPT-5)**只在这条接口上回思考摘要** ——
  /// `/chat/completions` 上它们想归想,一个字都不给你看。界面上挂在 OpenAI 那段下面
  /// 当一个开关,不单占一段:对用户来说它还是「OpenAI」。
  responses,

  /// Google Gemini(`/models/{model}:generateContent`,`x-goog-api-key`)。
  google,

  /// Anthropic(`/messages`,`x-api-key` + `anthropic-version`)。
  anthropic,
}

/// 分段选择器上那三个字。用大家叫得出口的名字(Gemini / Claude),
/// 不用公司名 —— 三段并排放不下「Google Gemini」这种长度。
/// [AgentApiFormat.responses] 不上分段(见那边),这个名字只出现在列表副行。
String agentApiFormatLabel(AgentApiFormat f) => switch (f) {
  AgentApiFormat.openai => 'OpenAI',
  AgentApiFormat.responses => 'OpenAI Responses',
  AgentApiFormat.google => 'Gemini',
  AgentApiFormat.anthropic => 'Claude',
};

/// 各家默认基址。用户留空时用它,省得为官方地址还要查一遍文档。
String agentApiDefaultBase(AgentApiFormat f) => switch (f) {
  AgentApiFormat.openai ||
  AgentApiFormat.responses => 'https://api.openai.com/v1',
  AgentApiFormat.google => 'https://generativelanguage.googleapis.com/v1beta',
  AgentApiFormat.anthropic => 'https://api.anthropic.com/v1',
};

/// 各家的对话接口路径。中转服务改路径是常事,所以它可填。
///
/// Gemini 那条**把模型名写在路径里**,所以用 `{model}` 占位,发请求时替换。
String agentApiDefaultPath(AgentApiFormat f) => switch (f) {
  AgentApiFormat.openai => '/chat/completions',
  AgentApiFormat.responses => '/responses',
  AgentApiFormat.google => '/models/{model}:generateContent',
  AgentApiFormat.anthropic => '/messages',
};

class CustomEndpoint {
  const CustomEndpoint({
    required this.id,
    required this.name,
    required this.format,
    required this.baseUrl,
    required this.apiKey,
    this._models = const [],
    String model = '',
    this.apiPath = '',
    this.headers = const {},
  }) : _picked = model;

  final String id;

  /// 界面上显示的名字。空的话拿模型名顶上。
  final String name;

  final AgentApiFormat format;

  /// 末尾无斜杠。空 = 用 [agentApiDefaultBase]。
  final String baseUrl;

  final String apiKey;

  final List<String> _models;

  /// 这一轮选中的模型(见 [model])。不落盘:选的是哪条存在模型偏好里,
  /// 发请求前由 `assistantEndpointProvider` 带进来。
  final String _picked;

  /// 这个接口上挂的全部模型 id,如 `gpt-5.6-luna` / `gemini-3.7-flash` / `claude-sonnet-5-5`。
  ///
  /// 同一个地址 + 同一把 Key 底下往往有一串模型可用(中转尤其如此),
  /// 一个模型配一遍接口等于把 Key 抄 N 遍,改 Key 还得改 N 处。
  /// 只给了 [model] 没给列表时,列表就是那一条。
  List<String> get models =>
      _models.isNotEmpty || _picked.isEmpty ? _models : [_picked];

  /// 这一轮要打的模型:选过的那条,没选过就是列表第一条。
  String get model =>
      _picked.isNotEmpty ? _picked : (_models.isEmpty ? '' : _models.first);

  /// 对话接口路径。空 = 用 [agentApiDefaultPath]。`{model}` 会被替换成模型名。
  final String apiPath;

  /// 自定义请求头,对话和拉模型列表都带。
  final Map<String, String> headers;

  /// [builtIn] 叠上 [headers]。头名不分大小写,同名的以 [headers] 为准。
  Map<String, String> withHeaders(Map<String, String> builtIn) {
    if (headers.isEmpty) return builtIn;
    final own = {for (final k in headers.keys) k.toLowerCase()};
    return {
      for (final h in builtIn.entries)
        if (!own.contains(h.key.toLowerCase())) h.key: h.value,
      ...headers,
    };
  }

  String get displayName => name.trim().isNotEmpty ? name.trim() : model;

  /// 选中这一条时顶栏显示什么。只挂一个模型时就是接口名;挂了一串时得显示
  /// 模型名 —— 不然切了模型顶栏纹丝不动,看不出这轮到底在用哪个。
  String get pickLabel => models.length > 1 ? model : displayName;

  /// 换一个模型发。不在列表里也照用(调用方负责只传列表里的)。
  CustomEndpoint withModel(String m) => copyWith(model: m);

  String get effectiveBase {
    final b = baseUrl.trim();
    return (b.isEmpty ? agentApiDefaultBase(format) : b).replaceAll(
      RegExp(r'/+$'),
      '',
    );
  }

  /// 拼在 [effectiveBase] 后面的那一段。开头补斜杠,`{model}` 就地替换。
  String get effectivePath {
    final raw = apiPath.trim().isEmpty
        ? agentApiDefaultPath(format)
        : apiPath.trim();
    final withSlash = raw.startsWith('/') ? raw : '/$raw';
    return withSlash.replaceAll('{model}', model.trim());
  }

  /// 完整的对话接口地址。
  Uri get chatUri => Uri.parse('$effectiveBase$effectivePath');

  /// 流式的对话接口地址。OpenAI / Claude 与 [chatUri] 同一个地址(开不开流由请求体
  /// 里的 `stream` 说了算),Gemini 得换方法名、还得带 `alt=sse` —— 不带 alt 回的是
  /// 一个巨大的 JSON 数组、要收完才能解析,等于没开流。
  ///
  /// 路径是用户可改的,所以只在认得出 `:generateContent` 时替换;中转把路径改成
  /// 别的样子时原样用它,顶多是流不起来,按非流式回落(见 `directModelStream`)。
  Uri get chatStreamUri {
    if (format != AgentApiFormat.google) return chatUri;
    final u = Uri.parse(
      '$effectiveBase${effectivePath.replaceFirst(':generateContent', ':streamGenerateContent')}',
    );
    return u.replace(queryParameters: {...u.queryParameters, 'alt': 'sse'});
  }

  /// 填全了才能用。缺一样就发不出去,列表里置灰。
  bool get usable => apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  CustomEndpoint copyWith({
    String? name,
    AgentApiFormat? format,
    String? baseUrl,
    String? apiKey,
    List<String>? models,
    String? model,
    String? apiPath,
    Map<String, String>? headers,
  }) => CustomEndpoint(
    id: id,
    name: name ?? this.name,
    format: format ?? this.format,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    models: models ?? _models,
    model: model ?? _picked,
    apiPath: apiPath ?? this.apiPath,
    headers: headers ?? this.headers,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'format': format.name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'models': models,
    // 老版本只认 `model` 这一个字段:装回老版本时至少第一个模型还在
    'model': models.isEmpty ? '' : models.first,
    if (apiPath.isNotEmpty) 'apiPath': apiPath,
    if (headers.isNotEmpty) 'headers': headers,
  };

  static CustomEndpoint? fromJson(Object? e) {
    if (e is! Map) return null;
    final id = e['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final list = e['models'];
    final single = e['model']?.toString().trim() ?? '';
    return CustomEndpoint(
      id: id,
      name: e['name']?.toString() ?? '',
      format:
          AgentApiFormat.values.asNameMap()[e['format']] ??
          AgentApiFormat.openai,
      baseUrl: e['baseUrl']?.toString() ?? '',
      apiKey: e['apiKey']?.toString() ?? '',
      // 老存档只有 `model` 一个字段
      models: list is List
          ? cleanModelList([for (final m in list) '$m'])
          : [if (single.isNotEmpty) single],
      apiPath: e['apiPath']?.toString() ?? '',
      headers: switch (e['headers']) {
        final Map h => {
          for (final x in h.entries)
            if ('${x.key}'.isNotEmpty) '${x.key}': x.value?.toString() ?? '',
        },
        _ => const {},
      },
    );
  }
}

/// 模型 id 列表去空白、去空、去重,保持原顺序(第一个是默认那条)。
List<String> cleanModelList(Iterable<String> raw) {
  final out = <String>[];
  for (final m in raw) {
    final t = m.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

final _headerName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
final _headerValue = RegExp(r'^[\x20-\x7E\t]*$');

/// 「名称: 值」一行一条 → 请求头。空行跳过,同名(不分大小写)后写的为准。
/// [bad] 是第一条不合格的行号(从 1 起),全合格为 null。
({Map<String, String> headers, int? bad}) parseHeaderLines(String text) {
  final out = <String, String>{};
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final at = line.indexOf(':');
    final name = at < 0 ? '' : line.substring(0, at).trim();
    final value = at < 0 ? '' : line.substring(at + 1).trim();
    if (!_headerName.hasMatch(name) || !_headerValue.hasMatch(value)) {
      return (headers: out, bad: i + 1);
    }
    out.removeWhere((k, _) => k.toLowerCase() == name.toLowerCase());
    out[name] = value;
  }
  return (headers: out, bad: null);
}

/// [parseHeaderLines] 的反向。
String formatHeaderLines(Map<String, String> headers) =>
    [for (final h in headers.entries) '${h.key}: ${h.value}'].join('\n');

final customEndpointsProvider =
    AsyncNotifierProvider<CustomEndpointsNotifier, List<CustomEndpoint>>(
      CustomEndpointsNotifier.new,
    );

class CustomEndpointsNotifier extends AsyncNotifier<List<CustomEndpoint>> {
  // 必须用共享的 secureStorageProvider,不能自建一个:两者当前配置相同,
  // 但一旦给共享那个加上 AndroidOptions(resetOnError 等),自建的这份会是
  // **唯一没跟上的**,而且编译器和 lint 都不会提醒。
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  var _seq = 0;

  String newId() => 'ep${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  @override
  Future<List<CustomEndpoint>> build() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const [];
      final j = jsonDecode(raw);
      if (j is! List) return const [];
      return [for (final e in j) ?CustomEndpoint.fromJson(e)];
    } catch (_) {
      // Keystore 还没就绪 / 读坏了 —— 按「没存过」处理,不崩。
      return const [];
    }
  }

  Future<void> _save(List<CustomEndpoint> next) async {
    state = AsyncData(next);
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode([for (final e in next) e.toJson()]),
      );
    } catch (_) {
      // 写不进去只影响下次冷启动,这一程照常能用
    }
  }

  /// 新增或就地替换(按 id)。
  Future<void> put(CustomEndpoint e) async {
    final list = [...state.value ?? const <CustomEndpoint>[]];
    final i = list.indexWhere((x) => x.id == e.id);
    if (i < 0) {
      list.add(e);
    } else {
      list[i] = e;
    }
    await _save(list);
  }

  Future<void> remove(String id) async {
    final list = [
      for (final e in state.value ?? const <CustomEndpoint>[])
        if (e.id != id) e,
    ];
    await _save(list);
  }
}
