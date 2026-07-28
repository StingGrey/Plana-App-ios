import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/editor/data/local_tag_db.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';

/// S3-02 的回归:词库解析搬进了后台 isolate(`compute`),
/// 而 `_Entry` 是个普通 Dart 类 —— 9 万个对象能不能跨 isolate 传回来,
/// 只有真跑一次才知道,静态分析看不出来。
///
/// 顺带把这个模块的基本检索行为钉住:此前它零测试覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '后台 isolate 解析 + 结果传回主 isolate(S3-02 回归)',
    () async {
      final db = LocalTagDb();
      final r = await db.search('1girl');
      expect(r, isNotEmpty, reason: '整条 compute 链路必须能把解析结果送回来');
      expect(r.first.text, '1girl');
      expect(r.first.kind, SuggestionKind.tag);
      expect(r.first.count, greaterThan(0), reason: '热度字段应随对象一起过来');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // 注意:结果是 [标签名命中..., 别名命中...] 两段拼接,**各段内**按热度降序,
  // 整体并非全局有序(实现注释明写)。所以这里不断言全局降序 —— 一个冷门的
  // 标签名命中本来就应该排在热门的别名命中前面。
  test('前缀匹配:标签名命中优先,下划线转空格', () async {
    final db = LocalTagDb();
    final r = await db.search('long_h', limit: 5);
    expect(r, isNotEmpty);
    expect(r.first.text, isNot(contains('_')), reason: '展示用空格而非下划线');
    expect(r.first.text, startsWith('long h'), reason: '标签名命中排在别名命中之前');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('查询短于 2 字符不检索(省得每敲一个字符扫全库)', () async {
    final db = LocalTagDb();
    expect(await db.search('a'), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('firstZh:多译只取第一个', () {
    expect(LocalTagDb.firstZh('少女,女孩'), '少女');
    expect(LocalTagDb.firstZh('长发、黑发'), '长发');
    expect(LocalTagDb.firstZh('a/b'), 'a');
    expect(LocalTagDb.firstZh(null), isNull);
    expect(LocalTagDb.firstZh(' , '), isNull);
  });
}
