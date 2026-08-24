// 画风的「适用模型」标注。
//
// 这套东西**不参与出图**,只用于灵感页的筛选和角标 —— 但 id 会随公共库和云备份
// 跟 web 互通,所以「不认识的 id 原样留着」这条比什么都重要:一端把另一端标过的
// 东西吞掉,是那种要等用户发现「我标的怎么没了」才暴露的坏。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/artist_models.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

void main() {
  group('normalizeArtistModels', () {
    test('丢空串、去重', () {
      expect(
        normalizeArtistModels(['v5-full', '', '  ', 'v5-full', 'krea-raw']),
        ['v5-full', 'krea-raw'],
      );
      expect(normalizeArtistModels(null), isEmpty);
      expect(normalizeArtistModels([]), isEmpty);
    });

    test('按目录顺序排,未知 id 排到末尾且保序', () {
      expect(
        normalizeArtistModels(['krea-raw', '未来的模型', 'v5-full', '另一个未来的']),
        ['v5-full', 'krea-raw', '未来的模型', '另一个未来的'],
      );
    });

    // 目录里没有的 id 可能来自更新的客户端,也可能是下线的模型。
    // 两种情况都不能吞 —— 吞了用户就再也改不回来。
    test('未知 id 不丢,展示名原样回显', () {
      expect(normalizeArtistModels(['某个新模型']), ['某个新模型']);
      expect(artistModelName('某个新模型'), '某个新模型');
      expect(artistModelShort('某个新模型'), '某个新模型');
      expect(findArtistModel('某个新模型'), isNull);
    });
  });

  group('artistModelGroups:角标按分档归并', () {
    test('同档多个模型只出一个角标', () {
      expect(artistModelGroups(['v5-full', 'v5-curated']), [
        ArtistModelGroup.naiV5,
      ]);
    });

    test('跨档按目录顺序列出', () {
      expect(artistModelGroups(['krea-raw', 'v4-full', 'v5-full']), [
        ArtistModelGroup.naiV5,
        ArtistModelGroup.naiV4,
        ArtistModelGroup.krea,
      ]);
    });

    test('没标注 / 只有未知 id → 没有角标', () {
      expect(artistModelGroups(null), isEmpty);
      expect(artistModelGroups(['某个新模型']), isEmpty);
    });
  });

  // 三类互斥,**通用是独立的一类** —— 标了别的档的串不该混进「通用」,
  // 否则「只看通用」会捞出一堆标过的。
  group('matchesArtistModelFilter', () {
    test('null = 全部', () {
      expect(matchesArtistModelFilter(null, null), isTrue);
      expect(matchesArtistModelFilter(['v5-full'], null), isTrue);
    });

    test('通用只捞没标注的', () {
      expect(matchesArtistModelFilter(null, kGenericModelFilter), isTrue);
      expect(matchesArtistModelFilter([], kGenericModelFilter), isTrue);
      expect(
        matchesArtistModelFilter(['v5-full'], kGenericModelFilter),
        isFalse,
      );
    });

    test('分档只捞标了这一档的,通用不混进来', () {
      final v5 = ArtistModelGroup.naiV5.name;
      expect(matchesArtistModelFilter(['v5-curated'], v5), isTrue);
      expect(matchesArtistModelFilter(['v4-full'], v5), isFalse);
      expect(matchesArtistModelFilter(null, v5), isFalse);
    });
  });

  // models 会进云备份,与 web 的 ArtistData.models 是同一个键。
  group('TagEntry 持久化', () {
    test('往返不丢', () {
      const e = TagEntry(
        id: 'a1',
        category: TagCategory.artist,
        name: 'A1',
        models: ['v5-full', 'krea-raw'],
      );
      expect(TagEntry.fromJson(e.toJson())!.models, ['v5-full', 'krea-raw']);
    });

    test('老数据没有这个键 → 通用', () {
      final e = TagEntry.fromJson(const {
        'id': 'a2',
        'category': 'artist-style',
        'name': 'A2',
      });
      expect(e!.models, isEmpty);
      expect(isGenericModels(e.models), isTrue);
      // 空列表不写进 JSON —— 备份文件不该为默认档多出一个键
      expect(e.toJson().containsKey('models'), isFalse);
    });
  });
}
