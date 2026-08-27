import 'dart:io';

/// 原子落盘:先写同目录的 `<name>.tmp`,再 rename 覆盖目标。
///
/// **为什么不能直接 `writeAsString` 覆写目标**:写到一半进程被杀就留下半截
/// 内容,下次 `jsonDecode` 抛异常 → 存档被判为损坏 → 静默降级成空档。而落盘
/// 时机(`AppStores.flushNow`)恰恰是**退后台**,正是系统最爱回收进程的时刻
/// —— 本意防丢的设计,反而在进程被杀时制造损坏文件。
///
/// 同目录 rename 在 ext4 / f2fs 上是原子的:要么旧内容完好、要么新内容完整,
/// 不存在中间态。`flush: true` 保证数据在 rename 前已交给内核。
///
/// 崩溃残留的 `.tmp` 无害:下次写入直接覆盖,且各处目录扫描都按扩展名过滤
/// (`.json` / `.bin` / `.png`),不会把它当成有效条目。
Future<void> writeStringAtomic(File target, String contents) async {
  await target.parent.create(recursive: true);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(target.path);
}

/// 二进制版,语义同 [writeStringAtomic]。
///
/// blob 仓尤其需要:那是**内容寻址**存储,半截文件的内容与文件名里的哈希
/// 对不上,却会被当作有效缓存命中 —— 比缺失更糟。
Future<void> writeBytesAtomic(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(target.path);
}
