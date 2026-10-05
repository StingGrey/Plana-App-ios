// 主提示词分区:界面层的分类,出图前按行序拼进主提示词。
//
// 容易坏的几处:生成快照里分区没拼进去(发出去少了画风)或拼了两遍;
// 停用的格子照样进了载荷;删到只剩主体时卡片回不到原样;编辑器把分区的词
// 写进了主提示词;读图导入后分区和导进来的整串重复;存档往返丢了分区。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/gen_modules.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/generate/state_codec.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart'
    show previewPieces;
import 'package:plana_app/features/inspiration/tag_models.dart';

class _Presets extends PromptPresetsNotifier {
  @override
  Future<PromptPresetsState> build() async =>
      const PromptPresetsState(presets: kDefaultPromptPresets);
}

const _a12 = TagEntry(
  id: 't1',
  category: TagCategory.artist,
  name: 'A12',
  positive: 'artist:wlop, artist:ask',
  negative: 'lowres, blurry',
);
const _watercolor = TagEntry(
  id: 't2',
  category: TagCategory.artist,
  name: '水彩厚涂',
  positive: 'watercolor (medium), impasto',
);

var _ids = 0;
String _nextId() => 'x${_ids++}';

List<String> _names(List<PromptSection> list) => [for (final s in list) s.name];

void main() {
  late ProviderContainer c;
  late GenerateNotifier gen;
  late AppStores stores;

  setUp(() async {
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        promptPresetsProvider.overrideWith(_Presets.new),
      ],
    );
    gen = c.read(generateProvider.notifier);
    gen.setPromptPreset('none'); // 拼出来的串里不掺质量词
    await c.read(promptPresetsProvider.future);
  });
  tearDown(() async {
    stores.flushNow();
    await stores.workspace.idle;
    c.dispose();
  });

  GenerateState st() => c.read(generateProvider);

  test('按行序拼:停用和空格子跳过,头尾逗号不重复', () {
    const sections = [
      PromptSection(id: 'a', name: '画风', positive: 'artist:wlop,'),
      PromptSection.main(),
      PromptSection(
        id: 'b',
        name: '场景',
        positive: 'night, rain',
        negative: 'sunny',
      ),
      PromptSection(id: 'c', name: '光影', positive: 'rim light', enabled: false),
      PromptSection(id: 'd', name: '镜头'),
    ];
    expect(
      joinSections(sections, '1girl, solo', positive: true),
      'artist:wlop, 1girl, solo, night, rain',
    );
    expect(joinSections(sections, 'lowres', positive: false), 'lowres, sunny');
    expect(joinSections(const [], 'x', positive: true), 'x');
  });

  test('前面已有的普通词后面不再重复;带记号的词和格内重复原样留着', () {
    const sections = [
      PromptSection.main(),
      PromptSection(
        id: 'a',
        name: '画风',
        negative: 'Lowres, blurry, {lowres}, jpeg artifacts',
      ),
    ];
    expect(
      joinSections(sections, 'lowres, bad anatomy, lowres', positive: false),
      'lowres, bad anatomy, lowres, blurry, {lowres}, jpeg artifacts',
    );
  });

  test('生成快照:分区拼进主提示词、不再带分区,主体的折叠草稿一并保住', () {
    final s = GenerateState.initial().copyWith(
      prompt: '1girl, solo',
      promptRaw: '<#人物: 1girl, solo#>',
      negativePrompt: 'bad anatomy',
      sections: withEntrySections(const [], '1girl, solo', [
        _a12,
      ], newId: _nextId),
    );
    final snap = stripHiddenModules(s, const GenModuleSettings());
    expect(snap.sections, isEmpty);
    expect(snap.prompt, '1girl, solo, artist:wlop, artist:ask');
    expect(snap.negativePrompt, 'bad anatomy, lowres, blurry');
    // 主体里原有的折叠还在,导回创作页时还是一个整体
    expect(parseFolds(snap.promptRaw).single.name, '人物');
    expect(pickEditorText(snap.promptRaw, snap.prompt), snap.promptRaw);
    // 没分区的快照原样过
    final plain = GenerateState.initial().copyWith(prompt: 'x');
    expect(stripHiddenModules(plain, const GenModuleSettings()).prompt, 'x');
  });

  test('灵感库条目各自成一格不折叠:一律接在最后,按加进来的先后往下排;重复的不另建', () {
    const rain = TagEntry(
      id: 's1',
      category: TagCategory.scene,
      name: '雨夜',
      positive: 'night, rain',
      negative: 'sunny',
    );
    var list = withEntrySections(const [], '1girl', [
      _a12,
      rain,
    ], newId: _nextId);
    // 主体留在原位,新格子按加进来的先后往下排
    expect(_names(list), ['主体', 'A12', '雨夜']);
    expect(list[1].artist, isTrue);
    expect(list[1].positive, 'artist:wlop, artist:ask');
    expect(list[1].positiveRaw, isEmpty); // 原样放进去,不折叠
    expect(list.last.negative, 'sunny');
    // 再来一个画风:不往上插,照样接在最后
    list = withEntrySections(list, '1girl', [_watercolor], newId: _nextId);
    expect(_names(list), ['主体', 'A12', '雨夜', '水彩厚涂']);
    // 同名同词停用着就打开;词已经全在提示词里的跳过
    list = [
      for (final s in list) s.name == 'A12' ? s.copyWith(enabled: false) : s,
    ];
    list = withEntrySections(list, '1girl', [
      _a12,
      const TagEntry(
        id: 'd',
        category: TagCategory.other,
        name: '重复',
        positive: 'night',
      ),
    ], newId: _nextId);
    expect(_names(list), ['主体', 'A12', '雨夜', '水彩厚涂']);
    expect(list[1].enabled, isTrue);
    // 角色也一样接在最后
    list = withEntrySections(list, '1girl', [
      const TagEntry(
        id: 'c1',
        category: TagCategory.character,
        name: '初音',
        positive: 'hatsune miku',
      ),
    ], newId: _nextId);
    expect(_names(list), ['主体', 'A12', '雨夜', '水彩厚涂', '初音']);
    // 什么都没加进去时,没分区的照旧没分区
    expect(
      withEntrySections(const [], 'night', [
        const TagEntry(
          id: 'e',
          category: TagCategory.other,
          name: '夜',
          positive: 'night',
        ),
      ], newId: _nextId),
      isEmpty,
    );
  });

  test('预览:折叠显示名字,禁用词剔掉,零散词照写', () {
    expect(previewPieces('1girl, ~smile~, <#A12: a, b#>, night'), [
      (text: '1girl', fold: false),
      (text: 'A12', fold: true),
      (text: 'night', fold: false),
    ]);
    expect(previewPieces(''), isEmpty);
  });

  test('加一格连主体一起建;删到只剩主体就回到没分区;撤销放回原位', () {
    gen.setPrompts(positive: '1girl');
    gen.addSection();
    expect([for (final s in st().sections) s.name], ['主体', '分区 1']);
    gen.addSection();
    expect(st().sections.last.name, '分区 2');
    final second = st().sections[1].id;
    final r1 = gen.removeSection(second)!;
    expect(r1.index, 1);
    final last = st().sections.last.id;
    final r2 = gen.removeSection(last)!;
    expect(st().sections, isEmpty);
    expect(st().prompt, '1girl');
    // 主体删不掉
    gen.addSection();
    expect(gen.removeSection(kMainSectionId), isNull);
    // 撤销:最后一格删掉时主体也没了,放回来连主体一起回来
    final restored = restoreSection(const [], r2.section, 1, main: r2.main);
    expect([for (final s in restored) s.id], [kMainSectionId, last]);
  });

  test('停用的格子不进载荷,读数口径也不算它', () {
    gen.setPrompts(positive: '1girl');
    gen.addSection();
    final id = st().sections.last.id;
    c
        .read(canvasWorkspaceProvider.notifier)
        .updatePrompts(
          c.read(canvasWorkspaceProvider).activeId,
          (p) => p.copyWith(
            sections: [
              for (final s in p.sections)
                s.id == id ? s.copyWith(positive: 'night') : s,
            ],
          ),
        );
    expect(sectionTexts(st().sections, positive: true), ['night']);
    gen.updateSection(id, enabled: false);
    expect(sectionTexts(st().sections, positive: true), isEmpty);
    expect(stripHiddenModules(st(), const GenModuleSettings()).prompt, '1girl');
  });

  test('读图导入整串替换:分区同一侧的词清掉、骨架留着;清空连分区一起清掉', () {
    gen.setPrompts(positive: '1girl', negative: 'lowres');
    gen.addEntrySections([_a12]);
    gen.replacePrompts(positive: 'artist:wlop, 2girls');
    final art = st().sections.firstWhere((s) => s.artist);
    expect(art.positive, isEmpty);
    expect(art.positiveRaw, isEmpty);
    expect(art.negative, 'lowres, blurry'); // 只导了正向,负面不动
    expect(st().prompt, 'artist:wlop, 2girls');
    gen.addEntrySections([_watercolor]);
    gen.clearPositive();
    expect(st().prompt, isEmpty);
    expect(st().sections, isEmpty); // 卡片回到没分区的样子
    expect(st().negativePrompt, 'lowres'); // 主体的负面留着
  });

  test('编辑器开着分区只写这一格,主提示词不动', () {
    gen.setPrompts(positive: '1girl');
    gen.addEntrySections([_a12]);
    final art = st().sections.firstWhere((s) => s.artist);
    final editor = c.read(editorProvider.notifier);
    editor.load(
      positive: pickEditorText(art.positiveRaw, art.positive),
      negative: art.negative,
      startPositive: true,
      sectionId: art.id,
    );
    editor.editActive('${c.read(editorProvider).positiveText}, sketch');
    editor.flushWriteBack();
    final after = st().sections.firstWhere((s) => s.artist);
    expect(after.positive, 'artist:wlop, artist:ask, sketch');
    expect(parseFolds(after.positiveRaw), isEmpty);
    expect(st().prompt, '1girl');
  });

  test('灵感库落地:每条自成一格、名字是分类名;角色也进分区,不进角色卡', () {
    const rain = TagEntry(
      id: 's1',
      category: TagCategory.scene,
      name: '雨夜',
      positive: 'night, rain',
      negative: 'sunny',
    );
    const miku = TagEntry(
      id: 'c1',
      category: TagCategory.character,
      name: '初音',
      positive: 'hatsune miku',
    );
    gen.setPrompts(positive: '1girl');
    gen.addEntrySections([_a12, rain, miku, _watercolor]);
    expect(_names(st().sections), ['主体', '画风', '场景', '角色', '画风']);
    expect(
      [for (final s in st().sections) s.positive],
      [
        '',
        'artist:wlop, artist:ask',
        'night, rain',
        'hatsune miku',
        'watercolor (medium), impasto',
      ],
    );
    expect(st().characters, isEmpty);
    expect(st().prompt, '1girl');
    expect(st().sections[2].negative, 'sunny');
    // 法典词条由调用方给名字
    gen.addEntrySections([
      const TagEntry(
        id: 'codex_1',
        category: TagCategory.other,
        name: '雨中回眸',
        positive: 'looking back, umbrella',
      ),
    ], name: '法典');
    expect(st().sections.last.name, '法典');
  });

  test('新画布沿用分区骨架、词清空;复制画布带上整组', () {
    gen.setPrompts(positive: '1girl');
    gen.addEntrySections([_a12]);
    final canvases = c.read(canvasWorkspaceProvider.notifier);
    canvases.create(duplicate: true);
    expect(st().sections.firstWhere((s) => s.artist).positive, isNotEmpty);
    canvases.create();
    expect(_names(st().sections), ['主体', '画风']);
    expect(st().sections.last.positive, isEmpty);
    expect(st().sections.last.negative, isEmpty);
    expect(st().prompt, isEmpty);
  });

  test('存档往返保留分区:顺序、名字、开关、草稿、画风标记', () async {
    final blobs = stores.blobs;
    final s = GenerateState.initial().copyWith(
      prompt: '1girl',
      sections:
          [
                ...withEntrySections(const [], '', [_a12], newId: _nextId),
                const PromptSection(
                  id: 'b',
                  name: '场景',
                  positive: 'night',
                  enabled: false,
                ),
              ]
              .map((x) => x.isMain ? const PromptSection.main(name: '人物') : x)
              .toList(),
    );
    final back = await decodeGenerateState(
      (await encodeGenerateState(s, blobs)).json,
      blobs,
    );
    expect(_names(back.sections), ['人物', 'A12', '场景']);
    expect(back.sections[1].artist, isTrue);
    expect(back.sections[1].positive, s.sections[1].positive);
    expect(back.sections.last.enabled, isFalse);
    expect(back.sections.first.isMain, isTrue);
    // 没分区的存档不写这个键
    final plain = await encodeGenerateState(GenerateState.initial(), blobs);
    expect(plain.json.containsKey('sections'), isFalse);
  });
}
