import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/store/atomic_file.dart';
import 'suggestions.dart';

/// 后端翻回来的译名(注音层里词库没有的短语、句子)在本机存一份。
///
/// 开机灌回反查缓存([cacheTagMeta]),写过的短语不用再问后端,断网也照样显示。
/// 只存翻出来的;按翻出来的先后留最近 [cap] 条。
class TransCacheStore {
  TransCacheStore(Directory root)
    : _file = File('${root.path}${Platform.pathSeparator}tag_trans_cache.json');

  final File _file;

  /// [metaKey] 形态的键 → 译名。插入序即新旧序,末尾最新。
  final _entries = <String, String>{};

  Timer? _debounce;
  bool _dirty = false;
  Future<void> _chain = Future.value();

  static const cap = 5000;

  /// 排队中的写全部落盘(测试用)。
  Future<void> get idle => _chain;

  int get length => _entries.length;

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString());
      if (j is! Map) return;
      for (final e in j.entries) {
        final k = e.key, v = e.value;
        if (k is String && v is String && v.isNotEmpty) {
          _entries[k] = v;
          cacheTagMeta(k, trans: v);
        }
      }
    } catch (_) {}
  }

  /// 记下一条译名,稍后落盘。
  void put(String key, String zh) {
    if (zh.isEmpty || _entries[key] == zh) return;
    _entries.remove(key);
    _entries[key] = zh;
    while (_entries.length > cap) {
      _entries.remove(_entries.keys.first);
    }
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), flush);
  }

  /// 有改动就立即落盘(退后台时调)。
  void flush() {
    _debounce?.cancel();
    _debounce = null;
    if (!_dirty) return;
    _dirty = false;
    final payload = jsonEncode(_entries);
    _chain = _chain
        .then((_) => writeStringAtomic(_file, payload))
        .catchError((Object _) {});
  }
}
