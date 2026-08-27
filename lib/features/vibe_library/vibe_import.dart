import 'package:file_picker/file_picker.dart';

import '../../core/util/file_read.dart';
import 'vibe_library.dart';

/// [ingestVibeFiles] 的结果:落库的条目 + 分类计数(报数用)。
typedef VibeIngest = ({
  List<VibeEntry> entries,
  int vibes,
  int images,
  int failed,
});

/// 用户选中的文件 → Vibe 库条目,按**内容**分流:JSON 开头(`{`)当 vibe 文件
/// 解析(单条或整包),否则当图片入库。选文件时不限扩展名,所以只能靠嗅探;
/// 单个文件失败只计数,不打断整批。
///
/// 只吃 `withData: false` 选来的文件:整包 vibe 可能上百 MB(图是 base64),
/// 按路径流式解析,图片则按需逐张读字节,不把整批一次性堆在内存里。
Future<VibeIngest> ingestVibeFiles(
  VibeLibrary lib,
  List<PlatformFile> files,
) async {
  final entries = <VibeEntry>[];
  var vibes = 0, images = 0, failed = 0;
  for (final f in files) {
    final base = f.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    try {
      if (await pickedStartsWith(f, 0x7B /* { */ )) {
        final got = await lib.importVibeJson(
          await readPickedJson(f),
          fallbackName: base,
        );
        entries.addAll(got);
        vibes += got.length;
      } else {
        entries.add(await lib.importImageBytes(await readPickedBytes(f), base));
        images++;
      }
    } catch (_) {
      failed++;
    }
  }
  return (entries: entries, vibes: vibes, images: images, failed: failed);
}
