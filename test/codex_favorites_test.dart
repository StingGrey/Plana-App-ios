// 法典收藏夹存的是词条**快照**(不是「法典 id + 词条 id」引用),
// 为的是打开收藏夹不必把整部法典拉起来解析。既然要落盘再读回,
// 这份快照就必须原样往返 —— 掉一个字段,收藏夹里那条就少一张图或少半段提示词,
// 而且用户是看不出来的(卡片照样渲染,只是内容不对)。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/codex/codex_favorites.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';

const _full = CodexEntry(
  id: 'e1',
  title: '雨后天台',
  tags: '1girl, 1.3::rooftop::, {rain}',
  path: ['场景', '室外'],
  image: 'a/b.webp',
  original: 'a/b.png',
  imageWidth: 832,
  imageHeight: 1216,
  assetRev: 'r7',
  assetCodexId: 'other',
  isNew: true,
  images: [CodexImage('a/1.webp', 'a/1.png'), CodexImage('a/2.webp', null)],
);

void main() {
  group('CodexEntry 快照往返', () {
    test('满字段原样回来', () {
      final back = CodexEntry.fromJson(_full.toJson());
      expect(back.id, _full.id);
      expect(back.title, _full.title);
      expect(back.tags, _full.tags);
      expect(back.path, _full.path);
      expect(back.image, _full.image);
      expect(back.original, _full.original);
      expect(back.imageWidth, _full.imageWidth);
      expect(back.imageHeight, _full.imageHeight);
      expect(back.assetRev, _full.assetRev);
      expect(back.assetCodexId, _full.assetCodexId);
      expect(back.isNew, isTrue);
      expect(back.images.map((i) => i.path), ['a/1.webp', 'a/2.webp']);
      expect(back.images.map((i) => i.original), ['a/1.png', null]);
      // 比例是瀑布流/网格定高的依据,尺寸丢了会塌成默认竖图
      expect(back.aspect, _full.aspect);
    });

    test('空字段不写进 JSON(几百条收藏,每条都省一串 null)', () {
      const bare = CodexEntry(id: 'x', title: 't', tags: 'a');
      final j = bare.toJson();
      expect(j.keys, ['id', 'title', 'tags']);
      final back = CodexEntry.fromJson(j);
      expect(back.hasImage, isFalse);
      expect(back.isNew, isFalse);
      expect(back.path, isEmpty);
    });
  });

  group('CodexFavorite', () {
    test('往返带上法典 id 与收藏时间', () {
      const f = CodexFavorite(codexId: 'c1', entry: _full, savedAt: 1700);
      final back = CodexFavorite.fromJson(f.toJson())!;
      expect(back.codexId, 'c1');
      expect(back.savedAt, 1700);
      expect(back.entry.tags, _full.tags);
      expect(back.key, f.key);
    });

    // 词条 id 只在自己那部法典里唯一。键不带法典 id 的话,两部法典各有一条
    // `e1` 就会互相顶掉 —— 收了 B 的,A 的那条星就灭了。
    test('键按「法典/词条」拼,跨法典同名 id 不互相顶', () {
      expect(codexFavKey('c1', 'e1'), isNot(codexFavKey('c2', 'e1')));
      const a = CodexFavorite(codexId: 'c1', entry: _full, savedAt: 1);
      const b = CodexFavorite(codexId: 'c2', entry: _full, savedAt: 2);
      expect(a.key, isNot(b.key));
    });

    // 收藏文件是本机 JSON,理论上可能被改坏/半截写入。坏行跳过即可,
    // 不能让一条脏数据把整个收藏夹带崩。
    test('脏数据一律跳过,不抛', () {
      expect(CodexFavorite.fromJson(null), isNull);
      expect(CodexFavorite.fromJson('oops'), isNull);
      expect(CodexFavorite.fromJson(const {'savedAt': 1}), isNull); // 缺法典 id
      expect(CodexFavorite.fromJson(const {'codexId': 'c1'}), isNull); // 缺词条
      expect(
        CodexFavorite.fromJson(const {
          'codexId': 'c1',
          'entry': {'title': 'x'}, // 词条 id 为空 = 定位不了,等于没有
        }),
        isNull,
      );
    });

    test('缺 savedAt 按 0 处理(仍能列出,只是排最后)', () {
      final f = CodexFavorite.fromJson({
        'codexId': 'c1',
        'entry': _full.toJson(),
      })!;
      expect(f.savedAt, 0);
    });
  });
}
