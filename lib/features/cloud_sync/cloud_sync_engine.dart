import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/platform/cloud_folder.dart';
import '../../core/store/atomic_file.dart';
import '../../core/util/log.dart';
import '../gallery/gallery_store.dart';
import '../local_gallery/local_gallery_store.dart';

/// 一轮同步的结果。
class CloudSyncReport {
  const CloudSyncReport({
    this.uploaded = 0,
    this.downloaded = 0,
    this.waiting = 0,
    this.failed = 0,
    this.firstError,
  });

  /// 本轮写进文件夹的张数。
  final int uploaded;

  /// 本轮从文件夹新加进本地图库的张数。
  final int downloaded;

  /// 文件夹里还只是 iCloud 占位、已请求系统下载的张数(下一轮再拉)。
  final int waiting;
  final int failed;
  final String? firstError;
}

/// 一轮同步走到哪一步。进度按阶段报,每段的总数从一开始就定死:要是合成一个
/// 总数,上传完才知道真正要拉几张,进度条会往回跳。
enum CloudSyncPhase {
  /// 列文件夹、比账本,还不知道要干多少活。
  checking,
  uploading,
  pulling,
}

/// 本机一张待上传的图:生成历史归 GalleryStore,外部导入归 LocalGalleryStore。
class _LocalImage {
  const _LocalImage(this.key, this.createdAt, this.ext, this.read);

  final String key;
  final int createdAt;
  final String ext;
  final Future<Uint8List?> Function() read;
}

/// 把图库同步到用户选的文件夹(通常在 iCloud Drive,见 [CloudFolder])。
///
/// **文件名即身份**:`Plana_<生成时刻>_<sha256 前 16 位>.<扩展名>`。同一张图不管
/// 在哪台设备算,哈希段都一样,所以「文件夹里已经有了」只比名字,不必把云端文件
/// 读回来比字节。时刻段让「文件」App 里按时间排得整齐,拉回时也用它还原生成时间
/// (文件 mtime 是上传时刻,不准)。
///
/// **本机账本**(`<support>/cloud_sync/state.json`):
/// - `uploaded`:本机条目 → 它在文件夹里的名字。哈希算过一次就不再读原图;
/// - `known`:见过的远端名字,拉回的、本机传的都算 —— 用户在本机删掉一张拉回来
///   的图,下一轮不会又被拉回来。
///
/// 删除**不**双向同步:哪边删都只删本机,文件夹里的原图要去「文件」App 删。
/// 同步最怕一次误删扩散到所有设备,这里宁可多留。
class CloudSyncEngine {
  CloudSyncEngine({
    required this.folder,
    required this.gallery,
    required this.localGallery,
    required Directory supportRoot,
  }) : _stateFile = File('${supportRoot.path}/cloud_sync/state.json');

  final CloudFolder folder;
  final GalleryStore gallery;
  final LocalGalleryStore localGallery;
  final File _stateFile;

  Map<String, String> _uploaded = {};
  Set<String> _known = {};
  int lastSyncAt = 0;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await _stateFile.exists()) return;
      final j = jsonDecode(await _stateFile.readAsString());
      if (j is! Map) return;
      lastSyncAt = (j['lastSyncAt'] as num?)?.toInt() ?? 0;
      final uploaded = j['uploaded'];
      if (uploaded is Map) {
        _uploaded = {
          for (final e in uploaded.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
        };
      }
      final known = j['known'];
      if (known is List) _known = {...known.whereType<String>()};
    } catch (e) {
      // 账本坏了只是退回首轮:按哈希比名字,不会重复上传,也不会重复导入。
      logd('[cloud-sync] 账本读取失败,按首轮同步: $e');
    }
  }

  /// 换了文件夹 / 断开:旧账本记的是另一个文件夹,必须作废。
  Future<void> reset() async {
    _loaded = true;
    _uploaded = {};
    _known = {};
    lastSyncAt = 0;
    try {
      if (await _stateFile.exists()) await _stateFile.delete();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await writeStringAtomic(
        _stateFile,
        jsonEncode({
          'v': 1,
          'lastSyncAt': lastSyncAt,
          'uploaded': _uploaded,
          'known': _known.toList(),
        }),
      );
    } catch (e) {
      logd('[cloud-sync] 账本保存失败: $e');
    }
  }

  List<_LocalImage> _localImages() => [
    for (final r in gallery.initialResults)
      _LocalImage(
        'h:${r.id}',
        r.createdAt,
        'png',
        () => gallery.readImage(r.id),
      ),
    for (final item in localGallery.initialItems)
      if (!item.isHistoryReference)
        _LocalImage(
          'l:${item.id}',
          item.createdAt,
          _extensionOf(item.fileName),
          () => localGallery.readImage(item.id),
        ),
  ];

  /// [pull]:把文件夹里本机没见过的图导入本地图库。
  /// [restoreAll]:忽略「见过」,把文件夹里本机没有的图全部拉回(重装后恢复用)。
  /// [onProgress]:`done / total` 是当前阶段内的计数;没活干的阶段不报。
  Future<CloudSyncReport> run({
    bool pull = true,
    bool restoreAll = false,
    void Function(CloudSyncPhase phase, int done, int total)? onProgress,
  }) async {
    onProgress?.call(CloudSyncPhase.checking, 0, 0);
    await load();
    final remote = [
      for (final e in await folder.list())
        if (isCloudImageName(e.name)) e,
    ];
    final remoteNames = {for (final e in remote) e.name};
    final remoteByHash = <String, String>{
      for (final e in remote) ?cloudHashOf(e.name): e.name,
    };

    final pending = [
      for (final image in _localImages())
        if (!_uploaded.containsKey(image.key)) image,
    ];
    final pulling = pull || restoreAll;
    var uploaded = 0, downloaded = 0, failed = 0;
    String? firstError;

    var done = 0;
    if (pending.isNotEmpty) {
      onProgress?.call(CloudSyncPhase.uploading, 0, pending.length);
    }
    for (final image in pending) {
      try {
        final bytes = await image.read();
        if (bytes != null && bytes.isNotEmpty) {
          final hash = sha256.convert(bytes).toString().substring(0, 16);
          var name = remoteByHash[hash];
          if (name == null) {
            name = cloudFileName(image.createdAt, hash, image.ext);
            await folder.write(name, bytes);
            remoteNames.add(name);
            remoteByHash[hash] = name;
            uploaded++;
          }
          _uploaded[image.key] = name;
          _known.add(name);
        }
      } catch (e) {
        failed++;
        firstError ??= '$e';
      }
      onProgress?.call(CloudSyncPhase.uploading, ++done, pending.length);
      // 首轮可能要传几百张;中途被杀也只丢最后这一截的记账
      if (done % 20 == 0) await _save();
    }

    final waiting = <String>[];
    if (pulling) {
      final local = {for (final image in _localImages()) ?_uploaded[image.key]};
      final toPull = [
        for (final e in remote)
          if (restoreAll ? !local.contains(e.name) : !_known.contains(e.name))
            e,
      ];
      done = 0;
      if (toPull.isNotEmpty) {
        onProgress?.call(CloudSyncPhase.pulling, 0, toPull.length);
      }
      void tick() =>
          onProgress?.call(CloudSyncPhase.pulling, ++done, toPull.length);
      for (final entry in toPull) {
        if (!entry.downloaded) {
          waiting.add(entry.name);
          tick();
          continue;
        }
        try {
          final bytes = await folder.read(entry.name);
          final before = localGallery.initialItems.length;
          final record = await localGallery.importBytes(
            bytes,
            entry.name,
            createdAt:
                cloudCreatedAtOf(entry.name) ??
                (entry.modifiedAt > 0 ? entry.modifiedAt : null),
          );
          if (localGallery.initialItems.length > before) downloaded++;
          final key = record.isHistoryReference
              ? 'h:${record.historyId}'
              : 'l:${record.id}';
          // 已有同内容的条目时保留它原先的名字:文件夹里同一张图有两份副本时,
          // 两个名字都进 known,谁也不会再被拉一次。
          _uploaded.putIfAbsent(key, () => entry.name);
          _known.add(entry.name);
        } catch (e) {
          failed++;
          firstError ??= '$e';
        }
        tick();
        if (done % 20 == 0) await _save();
      }
      if (waiting.isNotEmpty) {
        try {
          await folder.requestDownload(waiting);
        } catch (e) {
          logd('[cloud-sync] 请求下载失败: $e');
        }
      }
    }

    // 账本只留还活着的条目与文件夹里还在的名字,两边删图后不会越记越长。
    final liveKeys = {for (final image in _localImages()) image.key};
    _uploaded.removeWhere((key, _) => !liveKeys.contains(key));
    _known.retainWhere(remoteNames.contains);
    lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
    return CloudSyncReport(
      uploaded: uploaded,
      downloaded: downloaded,
      waiting: waiting.length,
      failed: failed,
      firstError: firstError,
    );
  }
}

final _imageNameRe = RegExp(
  r'\.(png|jpe?g|webp|gif|bmp)$',
  caseSensitive: false,
);
final _cloudNameRe = RegExp(
  r'^Plana_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_([0-9a-f]{16})\.[A-Za-z0-9]+$',
);

bool isCloudImageName(String name) =>
    !name.startsWith('.') && _imageNameRe.hasMatch(name);

/// 同步文件名。[createdAt] 为 0(老数据缺时刻)时用当前时间。
String cloudFileName(int createdAt, String hash16, String ext) {
  final t = createdAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(createdAt)
      : DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Plana_${t.year.toString().padLeft(4, '0')}${two(t.month)}'
      '${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}'
      '_$hash16.$ext';
}

/// 本应用写出的文件名里的哈希段;用户自己放进来的文件返回 null。
String? cloudHashOf(String name) => _cloudNameRe.firstMatch(name)?.group(7);

/// 从本应用写出的文件名还原生成时刻(本地时区)。
int? cloudCreatedAtOf(String name) {
  final m = _cloudNameRe.firstMatch(name);
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i)!);
  return DateTime(g(1), g(2), g(3), g(4), g(5), g(6)).millisecondsSinceEpoch;
}

String _extensionOf(String fileName) {
  final m = RegExp(r'\.([A-Za-z0-9]+)$').firstMatch(fileName);
  final ext = m?.group(1)?.toLowerCase();
  if (ext == null) return 'png';
  return ext == 'jpeg' ? 'jpg' : ext;
}
