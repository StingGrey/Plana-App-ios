// V5 那一批同步里**逻辑最绕**的三块:预设分系列 / autoText / 放大倍率。
//
// 三块的共同点是规则都不是自己定的 —— 全是照抄官方 bundle 里那几个函数,
// 而且每条都有「看着该这么算、实际不是」的地方(512×512 的 Max 档出 1024×1024
// 而不是 1774×1774;832×1216 的 1.5× 并不 64 对齐但官方照发;4.5 Light 和 V5
// Standard 的正面文本一模一样,只有前缀/后缀能区分)。这些必须钉死。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/gallery/upscale_model.dart';
import 'package:plana_app/features/generate/auto_text.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/gen_modules.dart'
    show retargetModel;
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';

PromptPreset _p(String id) =>
    kDefaultPromptPresets.firstWhere((p) => p.id == id);

const _custom = PromptPreset(
  id: 'custom_1',
  name: '我的档',
  positive: 'my quality',
  negative: 'my junk',
);

List<PromptPreset> get _all => [...kDefaultPromptPresets, _custom];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==================== 预设 × 模型系列 ====================

  group('内置档按系列分组', () {
    test('V5 只看到 v5 档,4.5 只看到 legacy 档', () {
      final v5 = promptPresetsForModel(_all, 'NAI 5.0 Full').map((p) => p.id);
      final legacy = promptPresetsForModel(
        _all,
        'NAI 4.5 Full',
      ).map((p) => p.id);
      expect(v5, ['v5-standard', 'v5-light', 'none', 'custom_1']);
      expect(legacy, ['heavy', 'light', 'none', 'custom_1']);
    });

    test('自定义档没有 scope,两边都留', () {
      for (final m in ['NAI 5.0 Curated', 'NAI 4.0 Full']) {
        expect(
          promptPresetsForModel(_all, m).any((p) => p.id == 'custom_1'),
          isTrue,
          reason: m,
        );
      }
    });
  });

  group('remapPromptPresetId:切模型时把档位映射过去', () {
    test('同强度档对着换', () {
      expect(remapPromptPresetId('heavy', _all, 'NAI 5.0 Full'), 'v5-standard');
      expect(remapPromptPresetId('light', _all, 'NAI 5.0 Full'), 'v5-light');
      expect(remapPromptPresetId('v5-standard', _all, 'NAI 4.5 Full'), 'heavy');
      expect(remapPromptPresetId('v5-light', _all, 'NAI 4.5 Full'), 'light');
    });

    test('当前模型仍然可选的档原样保留', () {
      expect(remapPromptPresetId('none', _all, 'NAI 5.0 Full'), 'none');
      expect(remapPromptPresetId('custom_1', _all, 'NAI 5.0 Full'), 'custom_1');
      expect(remapPromptPresetId('heavy', _all, 'NAI 4.5 Full'), 'heavy');
    });

    test('对不上任何档 → 落到列表首项', () {
      expect(remapPromptPresetId('已删除的档', _all, 'NAI 5.0 Full'), 'v5-standard');
    });
  });

  // 官方从 V4 起把质量词放**末尾**(UC 一律前缀)。老的 heavy/light 在我们这儿
  // 一直是前缀,改了会让存量用户出图风格突变 —— 所以只有 V5 档是后缀。
  group('applyPromptPreset:正面前缀 / 后缀,负面恒前缀', () {
    test('legacy 档拼前面', () {
      final r = applyPromptPreset(_p('heavy'), '1girl', 'bad');
      expect(r.positive.startsWith('best quality'), isTrue);
      expect(r.positive.endsWith('1girl'), isTrue);
      expect(r.negative.endsWith('bad'), isTrue);
    });

    test('V5 档拼后面', () {
      final r = applyPromptPreset(_p('v5-standard'), '1girl', 'bad');
      expect(r.positive.startsWith('1girl'), isTrue);
      expect(r.positive.endsWith('no text'), isTrue);
      // 负面仍然是前缀
      expect(r.negative.startsWith('lowres'), isTrue);
      expect(r.negative.endsWith('bad'), isTrue);
    });

    test('任一侧为空不留悬空逗号', () {
      final r = applyPromptPreset(_p('v5-light'), '', '');
      expect(r.positive, _p('v5-light').positive);
      expect(r.negative, _p('v5-light').negative);
      final none = applyPromptPreset(_p('none'), 'a', 'b');
      expect(none.positive, 'a');
      expect(none.negative, 'b');
    });
  });

  // 这张数字表和发送时那个 ucPreset **不是**一张表,别看串了。
  group('promptPresetTagHints', () {
    test('内置档报它文本实际取自的官方档', () {
      // OFFICIAL_PRESET_HINT_ORDER = [none, standard, heavy, light, humanFocus, ...]
      expect(promptPresetTagHints('v5-standard'), (qt: 1, ucPreset: 2));
      expect(promptPresetTagHints('v5-light'), (qt: 3, ucPreset: 3));
      expect(promptPresetTagHints('light'), (qt: 1, ucPreset: 3));
    });

    test('heavy 的正面是两段官方文本拼的,不对应单一官方档 → 只报负面', () {
      expect(promptPresetTagHints('heavy'), (qt: 0, ucPreset: 2));
    });

    test('自定义 / 未知 id 一律 none(0)', () {
      expect(promptPresetTagHints('none'), (qt: 0, ucPreset: 0));
      expect(promptPresetTagHints('custom_1'), (qt: 0, ucPreset: 0));
    });
  });

  // 导入时认档只是顺带,正题是**把预设文本剥回去** —— 不剥的话当前档下次生成
  // 会再拼一遍。所以判据只有一条:能不能干净剥掉。
  group('detectPromptPreset', () {
    ({String pos, String neg}) baked(PromptPreset p, String u, String n) {
      final r = applyPromptPreset(p, u, n);
      return (pos: r.positive, neg: r.negative);
    }

    test('认出档位并把文本剥回原样', () {
      for (final id in ['heavy', 'light', 'v5-standard', 'v5-light']) {
        final b = baked(_p(id), '1girl, smile', 'bad hands, blurry');
        final hit = detectPromptPreset(_all, b.pos, b.neg);
        expect(hit?.preset.id, id, reason: id);
        expect(hit?.positive, '1girl, smile', reason: id);
        expect(hit?.negative, 'bad hands, blurry', reason: id);
      }
    });

    // 这条是位置判据存在的**唯一理由**:两个档的正面文本一模一样。
    test('4.5 Light 与 V5 Standard 正面文本相同,靠前缀/后缀区分', () {
      expect(_p('light').positive, _p('v5-standard').positive);
      final l = baked(_p('light'), '1girl', 'bad');
      final v = baked(_p('v5-standard'), '1girl', 'bad');
      expect(detectPromptPreset(_all, l.pos, l.neg)?.preset.id, 'light');
      expect(detectPromptPreset(_all, v.pos, v.neg)?.preset.id, 'v5-standard');
    });

    test('正负两边都得剥得掉 —— 手打一个 masterpiece 不会误判', () {
      expect(
        detectPromptPreset(_all, 'very aesthetic, masterpiece, no text', 'bad'),
        isNull,
      );
      // 负面对上、正面对不上,同样不算
      expect(detectPromptPreset(_all, '1girl', _p('heavy').negative), isNull);
    });

    test('没套预设的图认不出 → null(调用方据此切到「无」)', () {
      expect(detectPromptPreset(_all, '1girl, smile', 'bad hands'), isNull);
    });

    // 自定义档一样参与识别 —— 用户自己建的档同样会被拼进提示词,
    // 不认它的话导入回来照样会重复拼。
    test('自定义档:正负成对的认得出、剥得干净', () {
      const mine = PromptPreset(
        id: 'custom_2',
        name: '我的档',
        positive: 'my style, soft light',
        negative: 'ugly, bad hands',
      );
      final all = [...kDefaultPromptPresets, mine];
      final b = baked(mine, '1girl, smile', 'blurry');
      final hit = detectPromptPreset(all, b.pos, b.neg);
      expect(hit?.preset.id, 'custom_2');
      expect(hit?.positive, '1girl, smile');
      expect(hit?.negative, 'blurry');
    });

    test('候选按 tag 总数倒序:自定义档不会把内置长档先啃掉', () {
      const short = PromptPreset(
        id: 'custom_3',
        name: '短档',
        positive: 'best quality',
        negative: 'lowres',
      );
      final all = [...kDefaultPromptPresets, short];
      final b = baked(_p('heavy'), '1girl', 'bad');
      expect(detectPromptPreset(all, b.pos, b.neg)?.preset.id, 'heavy');
    });

    // ⚠ 已知的锐角:**单边**自定义档退化成只验另一边,一个词的档极易误命中。
    // 这条不是在断言"应该这样",而是钉住现状 —— 面板会把识别结果显示出来
    // (「识别到:只有正面」),用户看得见也能取消勾选,所以没有静默删词。
    test('单边自定义档:判据退化成只验一边,可能误认', () {
      const posOnly = PromptPreset(
        id: 'custom_4',
        name: '只有正面',
        positive: 'masterpiece',
        negative: '',
      );
      final all = [...kDefaultPromptPresets, posOnly];
      // 这张图根本没套那个档,只是提示词恰好以 masterpiece 开头
      final hit = detectPromptPreset(all, 'masterpiece, 1girl', 'blurry');
      expect(hit?.preset.id, 'custom_4');
      expect(hit?.positive, '1girl');
    });

    test('tag_hint 只排序不定论:提示指向 v5-light,文本却是 heavy 的照样认 heavy', () {
      final b = baked(_p('heavy'), '1girl', 'bad');
      final hit = detectPromptPreset(
        _all,
        b.pos,
        b.neg,
        hintQt: 3,
        hintUcPreset: 3,
      );
      expect(hit?.preset.id, 'heavy');
    });
  });

  // ==================== autoText ====================

  group('autoText:引号内容 → teXt: 块', () {
    // 注意是**追加**,不是替换:引号原文留在提示词里,teXt: 块加在后面
    // (官方就是这么干的,stripAutoText 靠重算这个块来判断能不能剥)。
    test('抽出引号内容并追加到末尾,原文不动', () {
      expect(applyAutoText('1girl, "hello"'), '1girl, "hello", teXt: hello');
      expect(applyAutoText('1girl, 「你好」'), '1girl, 「你好」, teXt: 你好');
    });

    test('没有引号内容时原样返回', () {
      expect(applyAutoText('1girl, smile'), '1girl, smile');
    });

    // 不写下来就会忘的那几条
    test("don't / it's 里的撇号不当引号", () {
      expect(
        applyAutoText("1girl, don't care, it's fine"),
        "1girl, don't care, it's fine",
      );
    });

    test('用户手写了 text: 就完全不插手(不分大小写)', () {
      expect(
        applyAutoText('1girl, text: hi, "ignored"'),
        '1girl, text: hi, "ignored"',
      );
      expect(applyAutoText('1girl, TEXT: hi, "x"'), '1girl, TEXT: hi, "x"');
    });

    test('没有配对的收尾引号 → 当普通字符', () {
      expect(applyAutoText('1girl, "unclosed'), '1girl, "unclosed');
    });

    test('多段引号按顺序,用空行分隔', () {
      expect(applyAutoText('"a" and "b"'), '"a" and "b", teXt: a\n\nb');
    });

    // CJK 占比 >30% 时整体反转(竖排右起的阅读习惯)
    test('CJK 内容整体反转顺序', () {
      expect(applyAutoText('「甲」「乙」'), '「甲」「乙」, teXt: 乙\n\n甲');
    });

    test('多角色按阅读顺序:先按 y 分行,行内按 x', () {
      final out = applyAutoText(
        '2girls',
        characters: const [
          AutoTextChar(prompt: '"right"', center: (x: 0.8, y: 0.5)),
          AutoTextChar(prompt: '"left"', center: (x: 0.2, y: 0.5)),
        ],
        useCoords: true,
      );
      expect(out, '2girls, teXt: left\n\nright');
    });

    test('禁用的角色不参与', () {
      final out = applyAutoText(
        '1girl',
        characters: const [AutoTextChar(prompt: '"nope"', enabled: false)],
      );
      expect(out, '1girl');
    });

    test('stripAutoText 是逆操作;用户手改过就原样保留', () {
      const src = '1girl, "hello"';
      expect(stripAutoText(applyAutoText(src)), src);
      // 块被改过 → 认不出是自动加的,不动它
      expect(
        stripAutoText('1girl, "hello", teXt: 用户自己写的'),
        '1girl, "hello", teXt: 用户自己写的',
      );
    });
  });

  // ==================== 放大 / 超分 ====================

  group('V5 扩散超分', () {
    test('按源图像素查表 1–4 点', () {
      expect(naiV5UpscalePrice(1024, 1024), 1); // 1,048,576 = 表内第一档上界
      expect(naiV5UpscalePrice(1024, 1025), 2);
      expect(naiV5UpscalePrice(1216, 1436), 2); // 1,746,176
      expect(naiV5UpscalePrice(1408, 1728), 3); // 2,433,024
      expect(naiV5UpscalePrice(1024, 3072), 4); // 正好总像素上限
    });

    test('超过总像素上限官方不受理', () {
      expect(naiV5UpscalePrice(1024, 3073), isNull);
      expect(naiV5UpscaleSupportsSize(2048, 2048), isFalse);
    });

    // 没有分辨率白名单 —— 这正是它比传统超分好用的地方
    test('任意尺寸都收,不看白名单', () {
      expect(naiV5UpscaleSupportsSize(777, 999), isTrue);
      expect(naiUpscaleSupportsSize(777, 999), isFalse);
    });

    test('结果尺寸 = 边长向下对齐 16 再 ×2', () {
      expect(naiV5UpscaleTargetSize(832, 1216), (w: 1664, h: 2432));
      expect(naiV5UpscaleTargetSize(777, 999), (w: 1536, h: 1984));
    });
  });

  group('放大重绘的倍率档', () {
    // 实测值:512×512 的源图服务端返回 1024×1024。按"等比放到总像素上限"
    // 会算成 1774×1774,价格预估高出三倍 —— 这条就是防那个想当然。
    test('Max 档不是"放到上限",是先对齐 16 再 ×2', () {
      // 实测:512×512 的源图服务端返回 1024×1024。按"等比放到总像素上限"
      // 会算成 1774×1774,价格预估高出三倍。
      expect(enhanceMaxTargetSize(512, 512), (w: 1024, h: 1024));
      expect(enhanceMaxTargetSize(640, 640), (w: 1280, h: 1280));
    });

    test('×2 之后超上限才等比缩回,并对齐 32', () {
      // 832×1216 → 1664×2432 = 4.05M 超上限 → 缩回 1440×2144 = 3.09M
      expect(enhanceMaxTargetSize(832, 1216), (w: 1440, h: 2144));
      for (final wh in [(832, 1216), (1216, 1216), (1024, 1024)]) {
        final t = enhanceMaxTargetSize(wh.$1, wh.$2);
        expect(t.w * t.h <= kNaiMaxPixels, isTrue, reason: '$wh');
        expect(t.w % 32, 0, reason: '$wh');
        expect(t.h % 32, 0, reason: '$wh');
      }
    });

    test('Max 档只有 V5 给,且源图不能太大', () {
      expect(enhanceMaxAvailable(832, 1216, 'NAI 5.0 Full'), isTrue);
      expect(enhanceMaxAvailable(832, 1216, 'NAI 4.5 Full'), isFalse);
      // 0.8×上限 = 2,516,582.4
      expect(enhanceMaxAvailable(1600, 1600, 'NAI 5.0 Full'), isFalse);
    });

    // 832×1216 的 1.5× = 1248×1824,**不是** 64 对齐,按通则会被筛掉只剩 1× ——
    // 官方直接写死绕开,因为这是最常用的尺寸。
    test('832×1216 / 1216×832 特判成 1.5× + 1×', () {
      expect(enhanceScaleOptions(832, 1216, 'NAI 4.5 Full'), [
        EnhanceScale.x15,
        EnhanceScale.x1,
      ]);
      expect(enhanceTargetSize(832, 1216, EnhanceScale.x15), (
        w: 1248,
        h: 1824,
      ));
    });

    test('V5 时 Max 排在最前', () {
      expect(
        enhanceScaleOptions(832, 1216, 'NAI 5.0 Full').first,
        EnhanceScale.max,
      );
    });

    test('通则:必须 64 对齐且不超上限', () {
      // 1024×1024:2× 出 2048² = 4.19M 超上限被筛掉;1.5× 出 1536²
      // (64 对齐、2.36M 在上限内)留下
      expect(enhanceScaleOptions(1024, 1024, 'NAI 4.5 Full'), [
        EnhanceScale.x15,
        EnhanceScale.x1,
      ]);
      // 600×600:600×2=1200 不是 64 的倍数 → 按通则一档不剩,走兜底
      expect(enhanceScaleOptions(600, 600, 'NAI 4.5 Full'), [
        EnhanceScale.x2,
        EnhanceScale.x15,
        EnhanceScale.x1,
      ]);
    });

    test('导入的怪尺寸一档都对不齐时仍给档,由 enhanceTargetSize 补对齐', () {
      final opts = enhanceScaleOptions(777, 999, 'NAI 4.5 Full');
      expect(opts, isNotEmpty);
      final t = enhanceTargetSize(777, 999, EnhanceScale.x15);
      expect(t.w % 64, 0);
      expect(t.h % 64, 0);
    });
  });

  // 面板的参数整体持久化。改成一个对象存之前只存了「上次用哪种方式」,
  // 迁移那条路必须留着 —— 不然老用户一升级偏好就全丢。
  group('UpscaleSettings:持久化与迁移', () {
    test('往返不丢', () {
      const v = UpscaleSettings(
        method: UpscaleMethod.naiV5,
        enhanceScale: EnhanceScale.max,
        strength: 0.35,
        noise: 0.12,
      );
      final back = UpscaleSettings.fromJson(v.toJson());
      expect(back.method, v.method);
      expect(back.enhanceScale, v.enhanceScale);
      expect(back.strength, v.strength);
      expect(back.noise, v.noise);
    });

    test('老存档只有方式名 → 其余落默认', () {
      final v = UpscaleSettings.fromJson(const {'method': 'nai'});
      expect(v.method, UpscaleMethod.nai);
      expect(v.enhanceScale, EnhanceScale.x15);
      expect(v.strength, kRedrawStrength);
    });

    test('redraw15x 是改名前的存量值,照样认', () {
      expect(
        UpscaleSettings.fromJson(const {'method': 'redraw15x'}).method,
        UpscaleMethod.redraw,
      );
    });

    // 本地超分整条下线了,存量偏好里的两个本地档要落到默认档而不是崩掉。
    test('已下线的本地档 → 落默认', () {
      for (final v in ['localFast', 'localQuality']) {
        expect(
          UpscaleSettings.fromJson({'method': v}).method,
          UpscaleMethod.naiV5,
          reason: v,
        );
      }
    });

    test('越界/垃圾值夹回来,不整份丢掉', () {
      final v = UpscaleSettings.fromJson(const {
        'method': '不存在的方式',
        'enhanceScale': 'x99',
        'strength': 9.0,
        'noise': -1.0,
      });
      expect(v.method, UpscaleMethod.naiV5);
      expect(v.enhanceScale, EnhanceScale.x15);
      expect(v.strength, kStrengthMax);
      expect(v.noise, 0.0);
    });

    // 档位下拉高亮读的就是这个:两个滑杆微调过之后要能显示成「自定义」。
    test('magnitudeIndex:命中档位 / 微调后为 -1', () {
      expect(const UpscaleSettings().magnitudeIndex, 2); // 默认 = 档 3
      expect(
        const UpscaleSettings(strength: 0.7, noise: 0.1).magnitudeIndex,
        4,
      );
      expect(
        const UpscaleSettings(strength: 0.53, noise: 0).magnitudeIndex,
        -1,
      );
    });
  });

  // 「重绘放大」用创作页**当前**的模型跑,不是这张图当初那个 —— 所以快照
  // 换模型前要按新模型的能力面裁一遍,否则 4.5 的 Vibe 会被发进 V5 的请求。
  group('retargetModel:换模型时按能力面裁快照', () {
    GenerateState rich(String model) => GenerateState.initial().copyWith(
      prompt: '1girl',
      params: const GenParams().copyWith(model: model),
      characters: [
        for (var i = 0; i < 10; i++)
          CharacterPrompt(id: 'c$i', name: '角色$i', positive: 'c$i'),
      ],
    );

    test('模型换过去了', () {
      final out = retargetModel(rich('NAI 4.5 Full'), 'NAI 5.0 Full');
      expect(out.params.model, 'NAI 5.0 Full');
    });

    test('V5 不支持的模块整组去掉', () {
      final out = retargetModel(rich('NAI 4.5 Full'), 'NAI 5.0 Full');
      expect(out.vibes, isEmpty);
      expect(out.charRefs, isEmpty);
    });

    test('角色数按新模型的上限截断', () {
      // V5 上限 32 → 10 张全留;4.5 上限 6 → 只剩前 6 张
      expect(
        retargetModel(rich('NAI 4.5 Full'), 'NAI 5.0 Full').characters,
        hasLength(10),
      );
      expect(
        retargetModel(rich('NAI 5.0 Full'), 'NAI 4.5 Full').characters,
        hasLength(6),
      );
    });

    // 这条是这个函数不复用 stripHiddenModules 的**唯一理由**:那个会把 img2img
    // 一起剥掉,而重绘放大的底图正是 img2img,剥了整次放大就白跑。
    test('img2img 底图必须原样留着', () {
      final s = rich(
        'NAI 4.5 Full',
      ).copyWith(img2img: Img2ImgConfig(image: Uint8List.fromList([1, 2, 3])));
      final out = retargetModel(s, 'NAI 5.0 Full');
      expect(out.img2img?.image, isNotNull);
    });

    test('提示词与采样参数不动 —— 快照只换模型这一项', () {
      final src = rich('NAI 4.5 Full');
      final out = retargetModel(src, 'NAI 5.0 Full');
      expect(out.prompt, src.prompt);
      expect(out.params.steps, src.params.steps);
      expect(out.params.cfg, src.params.cfg);
    });
  });

  // upscaled_enhance 只有 Max 档才发:非 Max 带一个 false 会让官方按普通
  // img2img 处理,而这字段对老模型本就无意义。
  group('upscaled_enhance 只随 Max 档发出', () {
    GenerateState state({required bool max}) =>
        GenerateState.initial().copyWith(
          prompt: '1girl',
          params: const GenParams().copyWith(model: 'NAI 5.0 Full', seed: '1'),
        );

    Map<String, dynamic> direct(bool max) =>
        buildNaiPayload(
              state(max: max),
              presetId: 'none',
              img2img: (
                image: 'AAAA',
                strength: 0.5,
                noise: 0,
                upscaledEnhance: max,
              ),
            ).body['parameters']
            as Map<String, dynamic>;

    test('Max 档发,数值倍率不发', () {
      expect(direct(true)['upscaled_enhance'], isTrue);
      expect(direct(false).containsKey('upscaled_enhance'), isFalse);
    });

    test('bot 线同口径', () {
      final p = buildBotParams(
        state(max: true),
        seed: 1,
        presetId: 'none',
        img2img: (
          image: 'AAAA',
          strength: 0.5,
          noise: 0,
          upscaledEnhance: true,
        ),
      );
      expect(p['upscaledEnhance'], isTrue);
    });
  });
}
