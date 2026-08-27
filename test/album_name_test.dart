// 自定义相册名的清洗与「最近用过」维护。
// 名字会直接变成 `Pictures/<名字>/` 的目录名 —— 带非法字符会让保存整批失败,
// 所以清洗是保存前的硬门槛,不是装饰。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/gallery/save_settings.dart';

void main() {
  group('相册名清洗', () {
    test('剔除文件系统非法字符', () {
      expect(sanitizeAlbumName('a/b\\c:d*e?f"g<h>i|j'), 'abcdefghij');
    });

    test('压缩空白并去两端', () {
      expect(sanitizeAlbumName('  Plana   精选  '), 'Plana 精选');
      expect(sanitizeAlbumName('a\t\nb'), 'a b');
    });

    test('全非法/全空白 → 空串(调用方据此禁用确定)', () {
      expect(sanitizeAlbumName('///'), '');
      expect(sanitizeAlbumName('   '), '');
      expect(sanitizeAlbumName(''), '');
    });

    test('中文与常规字符原样保留', () {
      expect(sanitizeAlbumName('Plana 精选-2026_v2'), 'Plana 精选-2026_v2');
    });
  });

  group('最近用过的相册', () {
    test('新名字提到最前', () {
      const s = SaveSettings(recentAlbums: ['A', 'B']);
      expect(s.withAlbumUsed('C').recentAlbums, ['C', 'A', 'B']);
    });

    test('重复使用只提前不重复', () {
      const s = SaveSettings(recentAlbums: ['A', 'B', 'C']);
      expect(s.withAlbumUsed('C').recentAlbums, ['C', 'A', 'B']);
    });

    test('超出上限截断', () {
      final many = [for (var i = 0; i < SaveSettings.maxRecentAlbums; i++) 'a$i'];
      final s = SaveSettings(recentAlbums: many).withAlbumUsed('new');
      expect(s.recentAlbums.length, SaveSettings.maxRecentAlbums);
      expect(s.recentAlbums.first, 'new');
      expect(s.recentAlbums.contains('a${SaveSettings.maxRecentAlbums - 1}'), isFalse);
    });

    test('往返序列化保序', () {
      const s = SaveSettings(recentAlbums: ['X', 'Y']);
      final back = SaveSettings.fromJson(s.toJson());
      expect(back.recentAlbums, ['X', 'Y']);
      expect(back, s);
    });

    test('空列表不写进 JSON,读回也是空', () {
      const s = SaveSettings();
      expect(s.toJson().containsKey('recentAlbums'), isFalse);
      expect(SaveSettings.fromJson(s.toJson()).recentAlbums, isEmpty);
    });

    test('脏数据(非字符串/空串)被过滤', () {
      final back = SaveSettings.fromJson({
        'recentAlbums': ['ok', '', 1, null],
      });
      expect(back.recentAlbums, ['ok']);
    });
  });
}
