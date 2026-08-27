import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart';

/// 均衡强度(Normalize)。
///
/// 两条发图线都必须自己算这一步:NAI 的 normalize_reference_strength_multiple
/// 只对缓存模式生效,直传编码串时它不动手;后端也只是把标记原样转发。
/// 所以「开关拨了但强度没变」是这功能最容易悄悄退化的地方 —— 这里钉死。
GenerateState _state({required bool normalize}) =>
    GenerateState.initial().copyWith(
      prompt: '1girl',
      params: const GenParams().copyWith(normalizeVibe: normalize),
    );

const _vibes = <BotVibe>[
  (encodedVibe: 'a', strength: 0.8, infoExtracted: 1),
  (encodedVibe: 'b', strength: 0.8, infoExtracted: 1),
];

List<double> _botStrengths(bool normalize) {
  final p = buildBotParams(
    _state(normalize: normalize),
    seed: 1,
    presetId: 'heavy',
    vibes: _vibes,
  );
  return [
    for (final v in p['vibeReferences'] as List) (v['strength'] as num) + .0,
  ];
}

void main() {
  group('normalizeVibeStrengths', () {
    test('合计 >1 时按比例缩到合计 1', () {
      final out = normalizeVibeStrengths([0.8, 0.8], on: true);
      expect(out, [0.5, 0.5]);
    });

    test('合计 ≤1 时原样不动(不会被放大)', () {
      expect(normalizeVibeStrengths([0.3, 0.2], on: true), [0.3, 0.2]);
    });

    test('单张永远不动 —— 一张图归一化会把强度硬拉到 1', () {
      expect(normalizeVibeStrengths([2.0], on: true), [2.0]);
    });

    test('关掉就是各自独立相加', () {
      expect(normalizeVibeStrengths([0.8, 0.8], on: false), [0.8, 0.8]);
    });
  });

  test('直连线:开关同时管住载荷强度和标记位', () {
    Map naiParams(bool normalize) =>
        buildNaiPayload(
              _state(normalize: normalize),
              presetId: 'heavy',
              vibes: const [
                (encoded: 'a', strength: 0.8),
                (encoded: 'b', strength: 0.8),
              ],
            ).body['parameters']
            as Map;

    final on = naiParams(true);
    expect(on['reference_strength_multiple'], [0.5, 0.5]);
    expect(on['normalize_reference_strength_multiple'], isTrue);

    final off = naiParams(false);
    expect(off['reference_strength_multiple'], [0.8, 0.8]);
    expect(off['normalize_reference_strength_multiple'], isFalse);
  });

  test('bot 线:强度在本地算好再发,不指望后端归一化', () {
    expect(_botStrengths(true), [0.5, 0.5]);
    expect(_botStrengths(false), [0.8, 0.8]);
  });

  test('默认开启,老存档缺键也按开处理', () {
    expect(const GenParams().normalizeVibe, isTrue);
  });
}
