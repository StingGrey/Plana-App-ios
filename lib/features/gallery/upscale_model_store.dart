/// 本地超分模型的按需下载。**模型不随 APK 分发。**
///
/// **为什么直连上游、既不内置也不自建镜像**:Upscayl 的 `resources/models/`
/// 目录下既无 LICENSE 也无 README,逐个模型的授权条款上游从未写明;官方
/// discussion 里维护者只确认过"导出的图片可商用",**权重本身能否被第三方
/// 再分发始终没有答案**。直连官方仓 = 本应用从不分发权重,用户是自己从源站
/// 取的 —— 这把再分发问题整个绕开了,而不是赌它没事。
///
/// 见 docs/audit-findings.md F0-09。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/store/atomic_file.dart';
import '../../core/util/log.dart';

/// 模型下载/校验失败。`toString()` 直接给出可操作文案 —— 调用方是
/// `hintSnack('超分失败: $e')`,套上 `Bad state:` 前缀只会让用户困惑。
class UpscaleModelException implements Exception {
  const UpscaleModelException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 钉在 tag 上,**不能用 main**:main 随时可能改目录结构或换模型文件名,
/// 那会变成某天用户点超分才发现 404 的静默失效。tag 是不可变引用。
const _tag = 'v2.15.0';
const _base =
    'https://raw.githubusercontent.com/upscayl/upscayl/$_tag/resources/models';

/// 上游一个文件的锚点。大小与哈希都取自 $_tag,已与随包旧版逐字节比对一致。
class _Remote {
  const _Remote(this.file, this.bytes, this.sha256);

  final String file;
  final int bytes;
  final String sha256;

  String get url => '$_base/$file';
}

/// 每个模型 = 一个 `.param`(网络结构)+ 一个 `.bin`(权重)。
const _manifest = <String, List<_Remote>>{
  'upscayl-lite-4x': [
    _Remote(
      'upscayl-lite-4x.param',
      5019,
      '22174924330297357434ad21ed0af7f4b820008d2a502b492754d130d4142714',
    ),
    _Remote(
      'upscayl-lite-4x.bin',
      2435272,
      '85ee266b632a765a725425ba6a5620c088c8aa2939a03063b2d83b3462724cc1',
    ),
  ],
  'digital-art-4x': [
    _Remote(
      'digital-art-4x.param',
      30290,
      '2b8fb6e0ae4d2d85704ca08c119a2f5ea40add4f2ecd512eb7f4cd44b6127ed4',
    ),
    _Remote(
      'digital-art-4x.bin',
      8943500,
      'fe01c269cfd10cdef8e018ab66ebe750cf79c7af4d1f9c16c737e1295229bacc',
    ),
  ],
};

/// 上游出处,「关于」页与许可声明引用同一个常量,避免两处漂移。
const kUpscaleModelSource = 'https://github.com/upscayl/upscayl';
const kUpscaleModelTag = _tag;

/// 已登记的模型名(用于存储管理逐项列出)。
List<String> get upscaleModelNames => _manifest.keys.toList();

/// 该模型下载完需要多少字节(param + bin)。
int upscaleModelBytes(String model) =>
    (_manifest[model] ?? const []).fold(0, (a, r) => a + r.bytes);

Future<File> _fileOf(String name) async =>
    File('${(await getApplicationSupportDirectory()).path}/$name');

/// 两个文件是否都已就位(只看存在与大小,不逐次校验哈希 —— 哈希在下载时验过,
/// 每次超分都重算 8.5MB 的 sha256 是白烧几百毫秒)。
Future<bool> isUpscaleModelReady(String model) async {
  for (final r in _manifest[model] ?? const <_Remote>[]) {
    final f = await _fileOf(r.file);
    if (!await f.exists() || await f.length() != r.bytes) return false;
  }
  return true;
}

/// 确保模型就位,缺什么下什么。返回 `(paramPath, binPath)`。
///
/// [onProgress] 是**本次实际要下的**字节的比例 0~1(已就位的文件不计入)。
Future<(String, String)> ensureUpscaleModel(
  String model, {
  void Function(String stage)? onStage,
  void Function(double frac)? onProgress,
}) async {
  final files = _manifest[model];
  if (files == null) throw StateError('未登记的超分模型:$model');

  final missing = <(_Remote, File)>[];
  for (final r in files) {
    final f = await _fileOf(r.file);
    if (!await f.exists() || await f.length() != r.bytes) missing.add((r, f));
  }

  if (missing.isNotEmpty) {
    final total = missing.fold<int>(0, (a, m) => a + m.$1.bytes);
    final mb = (total / 1048576).toStringAsFixed(1);
    onStage?.call('下载模型 $mb MB…');
    var done = 0;
    for (final (r, f) in missing) {
      await _download(
        r,
        f,
        onBytes: (n) {
          done += n;
          onProgress?.call((done / total).clamp(0.0, 1.0));
        },
      );
    }
    logd('[upscale] 模型 $model 已下载($mb MB,来源 upscayl $_tag)');
  }

  final param = await _fileOf('$model.param');
  final bin = await _fileOf('$model.bin');
  return (param.path, bin.path);
}

/// 下载单个文件:流式收字节 → 校验 sha256 → 原子落盘。
///
/// **必须校验且必须原子写**。这是懒下载(`exists()` 就跳过):断流写进半截,
/// 下次 `exists()` 照样为 true → 永远拿半截模型喂 native、永远失败,用户没有
/// 任何自愈手段。rename 落盘后才可见,校验不过则整份丢弃。
Future<void> _download(
  _Remote r,
  File dst, {
  required void Function(int n) onBytes,
}) async {
  final client = http.Client();
  try {
    final res = await client
        .send(http.Request('GET', Uri.parse(r.url)))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw UpscaleModelException('模型下载失败(HTTP ${res.statusCode}),请稍后重试');
    }
    final buf = BytesBuilder(copy: false);
    // 单块 30s 无进展即判停滞 —— 否则连着的死连接会让进度条永远卡住。
    await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
      buf.add(chunk);
      onBytes(chunk.length);
    }
    final data = buf.takeBytes();
    final got = sha256.convert(data).toString();
    if (got != r.sha256) {
      throw UpscaleModelException('模型校验失败(${r.file}),下载不完整或被中间人改写,请重试');
    }
    await writeBytesAtomic(dst, data);
  } on TimeoutException {
    throw const UpscaleModelException('模型下载超时,请检查网络后重试');
  } on SocketException {
    throw const UpscaleModelException('连不上模型服务器,请检查网络后重试');
  } finally {
    client.close();
  }
}
