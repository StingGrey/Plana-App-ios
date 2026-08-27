import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/import/image_metadata.dart';
import 'package:plana_app/features/import/import_category.dart';

ImageMetadata _meta(String source, ImageSourceType type) => ImageMetadata(
  source: source,
  sourceType: type,
  prompt: 'x',
  negativePrompt: '',
  width: 1024,
  height: 1536,
  seed: '1',
);

final _naiImg = _meta('NovelAI V4.5', ImageSourceType.novelai);
final _animaImg = _meta('anima-turbo-v1.0', ImageSourceType.comfyui);
final _kreaImg = _meta('krea2_raw_fp8_scaled', ImageSourceType.comfyui);
final _thirdPartyImg = _meta('someRandomModel_v3', ImageSourceType.comfyui);
final _sdImg = _meta('SD XL', ImageSourceType.stableDiffusion);

void main() {
  test('当前模型 → 类别', () {
    expect(categoryOfModel('NAI 4.5 Full'), ModelCategory.nai);
    expect(categoryOfModel('Anima Base'), ModelCategory.comfy);
    expect(categoryOfModel('Krea 2 Raw'), ModelCategory.krea);
  });

  test('ComfyUI 图靠 UNET 文件名分 anima / krea', () {
    expect(kreaModelFromSource('krea2_turbo_fp8_scaled'), 'Krea 2 Turbo');
    expect(kreaModelFromSource('krea2_raw_fp8_scaled'), 'Krea 2 Raw');
    // 不带 krea2 前缀的一律不是 k2(别被 sd_xl_base 这类名字骗了)
    expect(kreaModelFromSource('anima-turbo-v1.0'), isNull);
    expect(comfyModelOfImage(_kreaImg), ModelCategory.krea);
    expect(comfyModelOfImage(_animaImg), ModelCategory.comfy);
    // 第三方模型认不出 → null,但这不代表不能导参数(见下面的跨家族用例)
    expect(comfyModelOfImage(_thirdPartyImg), isNull);
    expect(comfyModelOfImage(_naiImg), isNull);
  });

  test('家族只有两套:NAI 与 ComfyUI', () {
    expect(familyOfImage(_naiImg), ModelFamily.nai);
    expect(familyOfImage(_animaImg), ModelFamily.comfy);
    expect(familyOfImage(_kreaImg), ModelFamily.comfy);
    expect(familyOfImage(_thirdPartyImg), ModelFamily.comfy);
    expect(familyOfImage(_sdImg), isNull); // 两套都不沾
    expect(familyOfCategory(ModelCategory.krea), ModelFamily.comfy);
    expect(familyOfCategory(ModelCategory.comfy), ModelFamily.comfy);
    expect(familyOfCategory(ModelCategory.nai), ModelFamily.nai);
  });

  test('只有跨家族才退化成「只导提示词」', () {
    // 同家族内模型对不上不算跨类别 —— 步数/尺寸这些照导
    expect(isCrossCategory(_kreaImg, ModelCategory.comfy), isFalse);
    expect(isCrossCategory(_animaImg, ModelCategory.krea), isFalse);
    expect(isCrossCategory(_thirdPartyImg, ModelCategory.krea), isFalse);
    // 跨家族:参数体系真的对不上
    expect(isCrossCategory(_naiImg, ModelCategory.comfy), isTrue);
    expect(isCrossCategory(_kreaImg, ModelCategory.nai), isTrue);
    // 两套都不沾的(SD/A1111)对谁都算跨
    expect(isCrossCategory(_sdImg, ModelCategory.nai), isTrue);
    expect(isCrossCategory(_sdImg, ModelCategory.krea), isTrue);
  });

  test('「切换到 xx 模型」的推荐目标', () {
    expect(categoryOfImage(_naiImg), ModelCategory.nai);
    expect(categoryOfImage(_animaImg), ModelCategory.comfy);
    expect(categoryOfImage(_kreaImg), ModelCategory.krea);
    // 认不出模型 → 没有可推荐的切换目标(但参数照导,见上一条)
    expect(categoryOfImage(_thirdPartyImg), isNull);
    expect(categoryOfImage(_sdImg), isNull);
  });

  // 2026-08-10 起 k2 也能导 sampler/scheduler,但查的是 krea 自己那张表
  test('anima 四档都能从 UNET 文件名认回来', () {
    expect(animaModelFromSource('anima-turbo-v1.0'), 'Anima Turbo');
    expect(animaModelFromSource('anima-aesthetic-v1.1'), 'Anima Aesthetic');
    expect(animaModelFromSource('anima-aesthetic-v1.0b'), 'Anima Aesthetic');
    expect(animaModelFromSource('anima-base-v1.0'), 'Anima Base');
    // 社区版文件名不带用途词、带版本号,命名规律和官方三档不同
    expect(animaModelFromSource('Anima-2.9B-preview-v1'), 'Anima 2.9B Beta');
    expect(animaModelFromSource('sd_xl_base_1.0'), isNull);
  });

  test('krea 采样器白名单独立于 anima', () {
    expect(kreaSamplerLabel('er_sde'), 'ER SDE');
    expect(kreaSamplerLabel('uni_pc'), 'UniPC');
    expect(kreaSchedulerLabel('karras'), 'Karras'); // 在表内,只是 UI 会警告
    // 表外的值:服务端会静默回退档位默认,所以清单里该单项禁用
    expect(kreaSamplerLabel('dpm_2_ancestral'), isNull);
    expect(kreaSchedulerLabel('exponential'), isNull);
    expect(kreaSamplerLabel(null), isNull);
  });

  test('「模型」那一项导不了时说清是哪种情况', () {
    expect(
      foreignModelReason(_kreaImg, ModelCategory.comfy),
      contains('Krea 2'),
    );
    expect(
      foreignModelReason(_animaImg, ModelCategory.krea),
      contains('Anima'),
    );
    expect(foreignModelReason(_thirdPartyImg, ModelCategory.krea), '不是本机支持的模型');
  });
}
