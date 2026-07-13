import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

/// 流式生成的一帧:step 非空=中间预览,isFinal=终图。
typedef NaiFrame = ({int? step, bool isFinal, Uint8List bytes});

/// 订阅信息:剩余点数 + 是否 Opus(决定免费额度)。
typedef NaiSubscription = ({int anlas, bool isOpus});

/// NovelAI 直连客户端(v1:App 用用户自己的 Bearer token 直接打 NAI)。
/// 复刻后端 `novelai_web_ui/server/app.py` 的原生请求。
final naiClientProvider = Provider<NaiClient>((ref) => NaiClient());

class NaiException implements Exception {
  NaiException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => 'NaiException($status): $message';
}

class NaiClient {
  static const _imageHost = 'https://image.novelai.net';

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

  Map<String, String> _genHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'accept': '*/*',
        'origin': 'https://novelai.net',
        'referer': 'https://novelai.net/',
        'user-agent': _ua,
      };

  /// 流式端点头:NAI 前端每请求都带 x-correlation-id(6 hex)+ x-initiated-at。
  Map<String, String> _streamHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'accept': '*/*',
        'accept-language': 'en-US,en;q=0.9',
        'origin': 'https://novelai.net',
        'referer': 'https://novelai.net/',
        'user-agent': _ua,
        'x-correlation-id': _corrId(),
        'x-initiated-at': _isoNow(),
      };

  String _corrId() {
    final r = Random();
    return List<int>.generate(3, (_) => r.nextInt(256))
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String _isoNow() {
    final d = DateTime.now().toUtc();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p2(d.month)}-${p2(d.day)}'
        'T${p2(d.hour)}:${p2(d.minute)}:${p2(d.second)}.000Z';
  }

  /// 流式文生图:POST /ai/generate-image-stream。
  /// 响应为「4 字节大端长度 + msgpack 消息」帧序列,消息 {step_ix, image, code}:
  /// step_ix 非空=中间预览、为空=终图;code!=200=错误。单帧解析失败跳过(与后端一致)。
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
  }) async* {
    final uri = Uri.parse('$_imageHost/ai/generate-image-stream');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);

    var received = 0; // 诊断:累计字节
    var parseFails = 0; // 诊断:解析失败帧数
    String? firstParseErr;
    var yielded = 0;

    try {
      final payload = utf8.encode(jsonEncode(body));
      final req = await client.postUrl(uri);
      _streamHeaders(token).forEach(req.headers.set);
      req.contentLength = payload.length;
      req.add(payload);

      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        final text = await resp
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10), onTimeout: () => '');
        throw NaiException(_errorTextRaw(text, resp.statusCode),
            status: resp.statusCode);
      }

      final buf = <int>[];
      // 帧间隔超 90s 视为断流(出图步间通常 1~3s)
      await for (final chunk in resp.timeout(const Duration(seconds: 90))) {
        received += chunk.length;
        buf.addAll(chunk);
        var off = 0;
        while (buf.length - off >= 4) {
          final len = (buf[off] << 24) |
              (buf[off + 1] << 16) |
              (buf[off + 2] << 8) |
              buf[off + 3];
          if (len < 0 || len > (64 << 20)) {
            throw NaiException('流数据格式异常(帧长 $len)');
          }
          if (buf.length - off < 4 + len) break;
          final msgBytes =
              Uint8List.fromList(buf.sublist(off + 4, off + 4 + len));
          off += 4 + len;

          dynamic msg;
          try {
            msg = msgpack.deserialize(msgBytes);
          } catch (e) {
            parseFails++;
            firstParseErr ??= '$e';
            continue; // 与后端一致:坏帧跳过,不断流
          }
          if (msg is! Map) continue;

          final code = msg['code'];
          if (code != null && code != 200) {
            final m = msg['message'];
            throw NaiException(m is String ? m : '生成失败(code $code)',
                status: code is int ? code : null);
          }

          final img = msg['image'];
          if (img is List<int>) {
            final stepIx = msg['step_ix'];
            yielded++;
            yield (
              step: stepIx is int ? stepIx + 1 : null,
              isFinal: stepIx == null,
              bytes: img is Uint8List ? img : Uint8List.fromList(img),
            );
          }
        }
        if (off > 0) buf.removeRange(0, off);
      }

      if (yielded == 0) {
        final diag = StringBuffer('未收到图片帧(收到 $received 字节');
        if (parseFails > 0) diag.write(',$parseFails 帧解析失败:$firstParseErr');
        diag.write(')');
        throw NaiException(diag.toString());
      }
    } on NaiException {
      rethrow;
    } on TimeoutException {
      throw NaiException('生成超时,请重试');
    } on SocketException catch (e) {
      throw NaiException('无法连接 NovelAI:${e.message}');
    } on HandshakeException {
      throw NaiException('TLS 握手失败,当前网络可能拦截了 novelai.net');
    } catch (e) {
      throw NaiException('流式生成失败:$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 非流式回退:POST /ai/generate-image → zip,解出首张 PNG 字节。
  Future<Uint8List> generateImage({
    required String token,
    required Map<String, dynamic> body,
  }) async {
    final uri = Uri.parse('$_imageHost/ai/generate-image');
    final http.Response resp;
    try {
      resp = await http
          .post(uri, headers: _genHeaders(token), body: jsonEncode(body))
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      throw NaiException('网络错误:$e');
    }

    if (resp.statusCode != 200) {
      throw NaiException(_errorText(resp), status: resp.statusCode);
    }

    return _pngFromMaybeZip(resp.bodyBytes);
  }

  /// 从响应字节取 PNG:直接是 PNG(魔数 89 50 4E 47)就用,否则当 zip 解出第一个 png。
  Uint8List _pngFromMaybeZip(Uint8List bytes) {
    if (bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return bytes;
    }
    try {
      final zip = ZipDecoder().decodeBytes(bytes);
      for (final f in zip.files) {
        if (f.isFile && f.name.toLowerCase().endsWith('.png')) {
          return Uint8List.fromList(f.content as List<int>);
        }
      }
    } catch (e) {
      throw NaiException('解压结果失败:$e');
    }
    throw NaiException('结果中未找到图片');
  }

  /// NAI 官方超分:POST https://api.novelai.net/ai/upscale → zip,解出 PNG。
  /// ⚠️ 端点在 api. 子域(非 image.);仅支持 832×1216/1216×832/1024²,scale 固定 4,
  /// 直接扣用户账户 Anlas。
  Future<Uint8List> upscale({
    required String token,
    required String imageBase64,
    required int width,
    required int height,
    int scale = 4,
  }) async {
    final uri = Uri.parse('https://api.novelai.net/ai/upscale');
    final http.Response resp;
    try {
      resp = await http.post(
        uri,
        headers: {
          ..._genHeaders(token),
          'accept': 'application/zip',
        },
        body: jsonEncode({
          'image': imageBase64,
          'width': width,
          'height': height,
          'scale': scale,
        }),
      ).timeout(const Duration(seconds: 120));
    } catch (e) {
      throw NaiException('网络错误:$e');
    }
    if (resp.statusCode != 200) {
      throw NaiException(_errorText(resp), status: resp.statusCode);
    }
    return _pngFromMaybeZip(resp.bodyBytes);
  }

  /// 订阅信息:GET /user/subscription。
  /// anlas = 固定额 + 已购额;isOpus = tier==3 且 active/宽限期(与 web `novelai.ts` 一致)。
  Future<NaiSubscription> subscription(String token) async {
    final uri = Uri.parse('$_imageHost/user/subscription');
    final http.Response resp;
    try {
      resp = await http.get(uri, headers: {
        'Authorization': 'Bearer $token',
      }).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw NaiException('网络错误:$e');
    }
    if (resp.statusCode != 200) {
      throw NaiException(_errorText(resp), status: resp.statusCode);
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final steps = (data['trainingStepsLeft'] as Map?) ?? const {};
    final fixed = (steps['fixedTrainingStepsLeft'] as num?)?.toInt() ?? 0;
    final purchased = (steps['purchasedTrainingSteps'] as num?)?.toInt() ?? 0;
    final isOpus = data['tier'] == 3 &&
        (data['active'] == true || data['isGracePeriod'] == true);
    return (anlas: fixed + purchased, isOpus: isOpus);
  }

  /// Vibe 编码:POST /ai/encode-vibe(每次固定耗 2 Anlas)。
  /// 请求体 `{image: 原始 base64(无 data: 前缀), information_extracted, model}`;
  /// 直连响应是二进制向量 → base64 化(与 web token 模式 `btoa(binary)` 一致)。
  Future<String> encodeVibe({
    required String token,
    required String imageBase64,
    required double infoExtracted,
    required String model,
  }) async {
    final uri = Uri.parse('$_imageHost/ai/encode-vibe');
    final http.Response resp;
    try {
      resp = await http.post(
        uri,
        headers: {
          'accept': '*/*',
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'origin': 'https://novelai.net',
          'referer': 'https://novelai.net/',
        },
        body: jsonEncode({
          'image': imageBase64,
          'information_extracted': infoExtracted,
          'model': model,
        }),
      ).timeout(const Duration(seconds: 120));
    } catch (e) {
      throw NaiException('编码参考图失败:$e');
    }
    if (resp.statusCode != 200) {
      throw NaiException(_errorText(resp), status: resp.statusCode);
    }
    return base64Encode(resp.bodyBytes);
  }

  String _errorText(http.Response r) => _errorTextRaw(r.body, r.statusCode);

  String _errorTextRaw(String body, int code) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['message'] is String) return j['message'] as String;
    } catch (_) {}
    return switch (code) {
      401 => 'Token 无效或已过期',
      402 => '订阅 / 点数不足',
      429 => '并发过多或触发限流,请稍后重试',
      _ => '请求失败(HTTP $code)',
    };
  }
}
