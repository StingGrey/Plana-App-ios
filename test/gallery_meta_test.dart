// 图库展开页的时间分组/时刻徽标 + 检索索引的归一化/抽取。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/gallery/gallery_dates.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';

void main() {
  group('时间分组', () {
    final now = DateTime(2026, 7, 30, 12, 0);

    int ms(DateTime d) => d.millisecondsSinceEpoch;

    test('日键与段头文案', () {
      final today = ms(DateTime(2026, 7, 30, 9, 30));
      final yesterday = ms(DateTime(2026, 7, 29, 23, 59));
      final thisYear = ms(DateTime(2026, 1, 2));
      final lastYear = ms(DateTime(2025, 12, 31));

      expect(galleryDayLabel(galleryDayKey(today), now), '今天');
      expect(galleryDayLabel(galleryDayKey(yesterday), now), '昨天');
      expect(galleryDayLabel(galleryDayKey(thisYear), now), '1月2日');
      expect(galleryDayLabel(galleryDayKey(lastYear), now), '2025年12月31日');
    });

    test('跨月的昨天(月初)', () {
      final n = DateTime(2026, 8, 1, 8, 0);
      final y = ms(DateTime(2026, 7, 31, 20, 0));
      expect(galleryDayLabel(galleryDayKey(y), n), '昨天');
    });

    test('无时间戳归「更早」,不画时刻', () {
      expect(galleryDayKey(0), 0);
      expect(galleryDayLabel(0, now), '更早');
      expect(galleryTimeBadge(0), '');
    });

    test('时刻徽标补零', () {
      expect(galleryTimeBadge(ms(DateTime(2026, 7, 30, 9, 5))), '09:05');
      expect(galleryTimeBadge(ms(DateTime(2026, 7, 30, 23, 59))), '23:59');
    });
  });

  group('搜索归一化', () {
    test('大小写/下划线/权重记号/括号/全角逗号', () {
      expect(
        normalizeSearchText('1.2::Long_Hair::, {Blue  Eyes}, [x]，Tail'),
        'long hair, blue eyes, x,tail',
      );
    });

    test('保留冒号(artist:wlop 要搜得到)', () {
      expect(normalizeSearchText('Artist:WLOP'), 'artist:wlop');
    });

    test('查询词切分 AND 匹配', () {
      final text = normalizeSearchText('1girl, long_hair, blue eyes');
      expect(searchMatch(text, searchTerms('long hair')), isTrue);
      expect(searchMatch(text, searchTerms('LONG_HAIR, 1girl')), isTrue);
      expect(searchMatch(text, searchTerms('long hair, red')), isFalse);
      expect(searchMatch(text, searchTerms('')), isTrue); // 空查询全过
    });
  });

  group('快照轻量抽取', () {
    test('标准形状:模型 + 正向 + 角色正向(不带负向)', () {
      final m = metaOfSnapshotJson({
        'v': 1,
        'refs': const [],
        'state': {
          'prompt': '1girl, {Blue_Sky}',
          'negativePrompt': 'lowres',
          'characters': [
            {'positive': 'red eyes', 'negative': 'bad hands'},
            {'positive': ''},
          ],
          'params': {'model': 'NAI 4.5 Full', 'width': 832},
        },
      });
      expect(m, isNotNull);
      expect(m!.model, 'NAI 4.5 Full');
      expect(m.text, '1girl, blue sky, red eyes');
      expect(m.text.contains('lowres'), isFalse);
      expect(m.text.contains('bad hands'), isFalse);
    });

    test('params 缺失 → 模型空串(归「未知」桶)', () {
      final m = metaOfSnapshotJson({
        'state': {'prompt': 'solo', 'characters': const []},
      });
      expect(m!.model, '');
      expect(m.text, 'solo');
    });

    test('state 不是 map → null', () {
      expect(metaOfSnapshotJson({'state': 'oops'}), isNull);
      expect(metaOfSnapshotJson(const {}), isNull);
    });
  });
}
