import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../vibe_library/naiv4vibe_codec.dart' show kModelToEncodingKey;
import 'gen_modules.dart';
import 'lora_triggers.dart' show removeLoraTriggersFromPrompt;
import 'models.dart';
import 'nai_request.dart' show naiModelId;

final generateProvider = NotifierProvider<GenerateNotifier, GenerateState>(
  GenerateNotifier.new,
);

/// token 读数唯一的角色口径,规则见 [countedCharacters]:模块不可见
/// (anima 等)时整组不计,免得计数自己变大。
final countedCharactersProvider = Provider<List<CharacterPrompt>>((ref) {
  final ms = ref.watch(genModulesProvider).value ?? const GenModuleSettings();
  return countedCharacters(ref.watch(generateProvider), ms);
});

class GenerateNotifier extends Notifier<GenerateState> {
  int _idSeq = 100;

  @override
  GenerateState build() {
    // 启动水合 + 每次状态变更排队防抖落盘:重启回到原样工作台
    final ws = ref.watch(appStoresProvider).workspace;
    _idSeq = ws.idSeq;
    listenSelf((_, next) => ws.schedule(next, idSeq: _idSeq));
    return ws.initial ?? GenerateState.initial();
  }

  String _newId() => 'id${_idSeq++}';

  // ---- 面板开合 ----
  void togglePanel(Panel p) {
    final open = {...state.openPanels};
    open.contains(p) ? open.remove(p) : open.add(p);
    state = state.copyWith(openPanels: open);
  }

  void openPanel(Panel p) {
    if (state.openPanels.contains(p)) return;
    state = state.copyWith(openPanels: {...state.openPanels, p});
  }

  // ---- 角色 ----
  void addCharacter() {
    if (state.characters.length >= 6) return;
    final c = CharacterPrompt(
      id: _newId(),
      name: '角色 ${state.characters.length + 1}',
    );
    state = state.copyWith(characters: [...state.characters, c]);
    openPanel(Panel.characters);
  }

  void updateCharacter(
    String id, {
    String? name,
    String? positive,
    String? negative,
    String? positiveRaw,
    String? negativeRaw,
    bool? enabled,
    Object? position = const Object(),
    CharTab? activeTab,
  }) {
    final useSentinel = position is! String?;
    state = state.copyWith(
      characters: [
        for (final c in state.characters)
          if (c.id == id)
            useSentinel
                ? c.copyWith(
                    name: name,
                    positive: positive,
                    negative: negative,
                    positiveRaw: positiveRaw,
                    negativeRaw: negativeRaw,
                    enabled: enabled,
                    activeTab: activeTab,
                  )
                : c.copyWith(
                    name: name,
                    positive: positive,
                    negative: negative,
                    positiveRaw: positiveRaw,
                    negativeRaw: negativeRaw,
                    enabled: enabled,
                    position: position,
                    activeTab: activeTab,
                  )
          else
            c,
      ],
    );
  }

  void removeCharacter(String id) {
    state = state.copyWith(
      characters: state.characters.where((c) => c.id != id).toList(),
    );
  }

  void clearCharacters() => state = state.copyWith(characters: const []);

  /// 参数导入:把元数据角色写入(replace=完全覆盖清空原有;否则额外追加),
  /// 尊重 6 个上限。追加时名称按最终位置续号。position 'A1'..'E5',null=AUTO。
  void addCharactersFrom(
    List<({String positive, String negative, String? position})> chars, {
    required bool replace,
  }) {
    final base = replace ? <CharacterPrompt>[] : [...state.characters];
    for (final c in chars) {
      if (base.length >= 6) break;
      base.add(
        CharacterPrompt(
          id: _newId(),
          name: '角色 ${base.length + 1}',
          positive: c.positive,
          negative: c.negative,
          position: c.position,
        ),
      );
    }
    state = state.copyWith(characters: base);
    if (base.isNotEmpty) openPanel(Panel.characters);
  }

  /// 灵感页「加入角色」:带名追加(名字取自角色条目),尊重 6 个上限,
  /// 超出静默截断(对齐 web availableSlots 语义)。返回实际加入条数。
  int addNamedCharactersFrom(
    List<({String name, String positive, String negative})> chars,
  ) {
    final base = [...state.characters];
    var added = 0;
    for (final c in chars) {
      if (base.length >= 6) break;
      base.add(
        CharacterPrompt(
          id: _newId(),
          name: c.name.isNotEmpty ? c.name : '角色 ${base.length + 1}',
          positive: c.positive,
          negative: c.negative,
        ),
      );
      added++;
    }
    if (added > 0) {
      state = state.copyWith(characters: base);
      openPanel(Panel.characters);
    }
    return added;
  }

  void moveCharacter(String id, int delta) {
    final list = [...state.characters];
    final i = list.indexWhere((c) => c.id == id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= list.length) return;
    final c = list.removeAt(i);
    list.insert(j, c);
    state = state.copyWith(characters: list);
  }

  // ---- Vibe ↔ 角色参考 互斥 ----
  // 对齐 web「CR 和 Vibe 互斥」:启用/加入一方,即停用另一方的全部条目
  // (非破坏:另一方图片仍在列表里,只是禁用不发送;生成端只发启用的那一组)。
  List<CharRefItem> _charRefsDisabled() => [
    for (final r in state.charRefs)
      if (r.enabled) r.copyWith(enabled: false) else r,
  ];
  List<VibeItem> _vibesDisabled() => [
    for (final v in state.vibes)
      if (v.enabled) v.copyWith(enabled: false) else v,
  ];

  // ---- Vibe ----
  String addVibe({
    Uint8List? image,
    required String name,
    String? imageHash,
    double strength = 0.6,
    double infoExtracted = 1.0,
    Map<String, String>? encodedByModel,
    String? sourceId,
  }) {
    // 无图也无编码的条目无法参与生成,拒收
    if (image == null && (encodedByModel == null || encodedByModel.isEmpty)) {
      return '';
    }
    final id = _newId();
    state = state.copyWith(
      vibes: [
        ...state.vibes,
        VibeItem(
          id: id,
          name: name,
          image: image,
          imageHash: imageHash,
          strength: strength,
          infoExtracted: infoExtracted,
          encodedByModel: encodedByModel,
          sourceId: sourceId,
        ),
      ],
      charRefs: _charRefsDisabled(), // 与角色参考互斥
    );
    openPanel(Panel.vibe);
    return id;
  }

  void updateVibe(String id, {double? strength, double? infoExtracted}) {
    state = state.copyWith(
      vibes: [
        for (final v in state.vibes)
          if (v.id == id)
            v.copyWith(strength: strength, infoExtracted: infoExtracted)
          else
            v,
      ],
    );
  }

  void removeVibe(String id) {
    state = state.copyWith(
      vibes: state.vibes.where((v) => v.id != id).toList(),
    );
  }

  /// 停用「缺当前模型编码的纯编码 Vibe」:无原图无从现场编码,
  /// 生成时只会被静默跳过。生成入口调用,返回停用数量供提示。
  int disableVibesMissingEncoding() {
    // vibe 模块当前不可见(隐藏/父类不符)时本就不发送,不停用也不提示
    final mods =
        ref.read(genModulesProvider).value ?? const GenModuleSettings();
    if (!mods.isVisibleFor(GenModule.vibe, state.params.model)) return 0;
    final model = naiModelId(state.params.model);
    final key = kModelToEncodingKey[model] ?? model;
    bool missing(VibeItem v) =>
        v.enabled && v.isEncodingOnly && v.encodedByModel?[key] == null;
    final hit = state.vibes.where(missing).length;
    if (hit == 0) return 0;
    state = state.copyWith(
      vibes: [
        for (final v in state.vibes)
          missing(v) ? v.copyWith(enabled: false) : v,
      ],
    );
    return hit;
  }

  void setVibeEnabled(String id, bool enabled) {
    state = state.copyWith(
      vibes: [
        for (final v in state.vibes)
          if (v.id == id) v.copyWith(enabled: enabled) else v,
      ],
      // 启用 Vibe 即停用角色参考(互斥);停用时不动另一方
      charRefs: enabled ? _charRefsDisabled() : null,
    );
  }

  /// 整体替换 vibe 列表(Vibe 管理器 / 角色参考图库按**返回键**还原进入前
  /// 快照用;参数导入「完全覆盖」传 const [] 先清空再逐个 addVibe)。
  void restoreVibes(List<VibeItem> vibes) =>
      state = state.copyWith(vibes: vibes);

  // ---- 角色参考 ----
  String addCharRef({
    required Uint8List image,
    required String name,
    String? imageHash,
  }) {
    final id = _newId();
    state = state.copyWith(
      charRefs: [
        ...state.charRefs,
        CharRefItem(id: id, name: name, image: image, imageHash: imageHash),
      ],
      vibes: _vibesDisabled(), // 与 Vibe 互斥
    );
    openPanel(Panel.charRef);
    return id;
  }

  void updateCharRef(
    String id, {
    CharRefMode? mode,
    double? strength,
    double? infoExtracted,
  }) {
    state = state.copyWith(
      charRefs: [
        for (final r in state.charRefs)
          if (r.id == id)
            r.copyWith(
              mode: mode,
              strength: strength,
              infoExtracted: infoExtracted,
            )
          else
            r,
      ],
    );
  }

  void removeCharRef(String id) {
    state = state.copyWith(
      charRefs: state.charRefs.where((r) => r.id != id).toList(),
    );
  }

  void setCharRefEnabled(String id, bool enabled) {
    state = state.copyWith(
      charRefs: [
        for (final r in state.charRefs)
          if (r.id == id) r.copyWith(enabled: enabled) else r,
      ],
      // 启用角色参考即停用 Vibe(互斥);停用时不动另一方
      vibes: enabled ? _vibesDisabled() : null,
    );
  }

  /// 整体替换角色参考列表(角色参考图库 / Vibe 管理器按**返回键**还原进入前
  /// 快照用 —— 两边互斥,还原一方必须连另一方一起还)。
  void restoreCharRefs(List<CharRefItem> refs) =>
      state = state.copyWith(charRefs: refs);

  // ---- LoRA(anima 专属) ----
  /// LoRA 管理器「确认挂载」:按选中卡整体替换挂载列表。
  /// 已挂条目保留用户调过的 weight/enabled(注册表字段刷新),新条目用推荐值;
  /// 超出上限截断,返回实际挂载数供调用方提示。
  int applyLoraSelection(List<ActiveLora> picked) {
    final byName = {for (final l in state.loras) l.name: l};
    final next = <ActiveLora>[];
    for (final p in picked) {
      if (next.length >= kMaxActiveLoras) break;
      final old = byName[p.name];
      next.add(
        old == null
            ? p
            : p.copyWith(
                weight: old.weight,
                enabled: old.enabled,
                clipWeight: old.clipWeight,
              ),
      );
    }
    state = state.copyWith(loras: next);
    if (next.isNotEmpty) openPanel(Panel.lora);
    return next.length;
  }

  void updateLora(
    String name, {
    double? weight,
    bool? enabled,
    double? clipWeight,
    bool clearClipWeight = false,
  }) {
    state = state.copyWith(
      loras: [
        for (final l in state.loras)
          if (l.name == name)
            l.copyWith(
              weight: weight,
              enabled: enabled,
              clipWeight: clipWeight,
              clearClipWeight: clearClipWeight,
            )
          else
            l,
      ],
    );
  }

  /// 占位条转正:按占位 name 找到那条,原地换成装好的真条目。
  ///
  /// 位置不动(用户已经在心里给它排好序了),并保留下载期间他改过的权重/启停;
  /// 同一个 LoRA 已经从别处挂上了就把占位的撤掉,不留两条。
  ///
  /// **占位条不在了就什么都不做**(返回 false,调用方只报「已下载」)——
  /// 那意味着用户在下载期间把它移除了,或者中途载入了别的工作区/快照。
  /// 这两种情况下他手上的配置里都没有这一条,下载完再塞回去就是个幽灵改动:
  /// 明明点了移除,过几分钟它自己又回来了。装好的本体在库里,要用去挂载即可。
  bool promotePendingLora(String placeholder, ActiveLora real) {
    final idx = state.loras.indexWhere((l) => l.name == placeholder);
    if (idx < 0) return false;
    final old = state.loras[idx];
    final dup = state.loras.any((l) => l.name == real.name);
    state = state.copyWith(
      loras: [
        for (var i = 0; i < state.loras.length; i++)
          if (i != idx)
            state.loras[i]
          else if (!dup)
            real.copyWith(
              weight: old.weight,
              enabled: old.enabled,
              clipWeight: old.clipWeight,
            ),
      ],
    );
    return true;
  }

  /// 占位条下载失败:标红并停用,留在原地等用户处理(移除或重新导入)。
  void markLoraFailed(String placeholder, String reason) {
    if (!state.loras.any((l) => l.name == placeholder)) return;
    state = state.copyWith(
      loras: [
        for (final l in state.loras)
          if (l.name == placeholder)
            l.copyWith(
              enabled: false,
              pending: LoraPending(
                versionId: l.pending?.versionId ?? 0,
                failed: reason,
              ),
            )
          else
            l,
      ],
    );
  }

  void removeLora(String name) {
    final victim = [
      for (final l in state.loras)
        if (l.name == name) l,
    ];
    final rest = state.loras.where((l) => l.name != name).toList();
    state = state.copyWith(loras: rest);
    // 删 LoRA 连带收走它在场的触发词;其他在架 LoRA(含暂禁用的)仍占用
    // 的 tag 留下。setPrompts 顺带作废编辑器原文草稿(编辑器外改写语义)。
    if (victim.isEmpty || victim.first.triggerWords.isEmpty) return;
    final cleaned = removeLoraTriggersFromPrompt(
      state.prompt,
      victim.first.triggerWords,
      keepTriggers: [for (final l in rest) l.triggerWords],
    );
    if (cleaned != state.prompt) setPrompts(positive: cleaned);
  }

  // ---- 重绘放大(anima 专属) ----
  /// 局部更新 hires 配置。[steps] 除 0(跟随主步数)外钳进服务端可接受的
  /// [kHiresStepsMin]~[kHiresStepsMax] —— 否则滑杆停在 2、后端按 4 跑,读数骗人。
  /// 从关到开时顺手展开面板,和挂 LoRA / 选底图的手感一致。
  void updateHires({
    bool? enabled,
    double? scale,
    double? denoise,
    int? steps,
    bool? useModel,
    HiresUpscaler? model,
  }) {
    final cur = state.params.hires;
    final next = cur.copyWith(
      enabled: enabled,
      scale: scale,
      denoise: denoise,
      steps: steps == null || steps == 0
          ? steps
          : steps.clamp(kHiresStepsMin, kHiresStepsMax),
      useModel: useModel,
      model: model,
    );
    state = state.copyWith(params: state.params.copyWith(hires: next));
    if (next.enabled && !cur.enabled) openPanel(Panel.hires);
  }

  // ---- 图生图 ----
  /// 选定底图:存原图 + 自动把生成分辨率设成图片尺寸(64 对齐/像素封顶,调用方已算好)。
  void setImg2ImgImage({
    required Uint8List image,
    required int width,
    required int height,
  }) {
    final cur = state.img2img;
    state = state.copyWith(
      img2img: Img2ImgConfig(
        image: image,
        strength: cur?.strength ?? 0.7,
        noise: cur?.noise ?? 0.0,
      ),
      params: state.params.copyWith(width: width, height: height),
    );
    openPanel(Panel.i2i);
  }

  void updateImg2Img({double? strength, double? noise}) {
    final cur = state.img2img;
    if (cur == null) return;
    state = state.copyWith(
      img2img: cur.copyWith(strength: strength, noise: noise),
    );
  }

  void disableImg2Img() => state = state.copyWith(img2img: null);

  // ---- 提示词(编辑器实时回写) ----
  /// 提示词写入。[positiveRaw] / [negativeRaw] 是编辑器原文草稿(含禁用、
  /// 折叠等仅编辑期语法),**传了就照写**;不传则视为编辑器之外的写入方,
  /// 只有该侧定稿真的变了才清掉旧草稿(它必然已过期)。
  ///
  /// 「传了才写」这条不能简化成「定稿变了才写」:**折叠不改变定稿**
  /// (outputOf 会把记号剥掉),编辑器加一个折叠组时 positive 一字未变、
  /// 只有草稿变了,按定稿判断会把这次折叠直接丢掉。
  /// 反过来「没传就清」也不能简化成无条件清:外部写入方传入的值可能与
  /// 现值相同(灵感页去重后没有新增),那一侧的禁用词不该因此蒸发。
  void setPrompts({
    String? positive,
    String? negative,
    String? positiveRaw,
    String? negativeRaw,
  }) {
    final nextRawP =
        positiveRaw ??
        (positive != null && positive != state.prompt ? '' : state.promptRaw);
    final nextRawN =
        negativeRaw ??
        (negative != null && negative != state.negativePrompt
            ? ''
            : state.negativePromptRaw);
    // 编辑器防抖回写高频触发,同值短路避免无谓的状态通知与落盘
    if ((positive ?? state.prompt) == state.prompt &&
        (negative ?? state.negativePrompt) == state.negativePrompt &&
        nextRawP == state.promptRaw &&
        nextRawN == state.negativePromptRaw) {
      return;
    }
    state = state.copyWith(
      prompt: positive,
      negativePrompt: negative,
      promptRaw: nextRawP,
      negativePromptRaw: nextRawN,
    );
  }

  // ---- 参数 ----
  void applyParams(GenParams params) => state = state.copyWith(params: params);

  /// 参数导入:按元数据回填生成参数(仅传入非空字段生效,copyWith 忽略 null)。
  /// 元数据导入落地。只传要改的字段,null = 保持不动。
  ///
  /// NAI 与 Anima 是两套独立的采样参数(前者 steps/cfg/sampler/noiseSchedule,
  /// 后者 anima*),width/height/seed 则两边共用 —— 调用方按图的模型类别决定传哪组。
  void applyImportedSettings({
    String? model,
    int? width,
    int? height,
    int? steps,
    double? cfg,
    double? cfgRescale,
    bool? varietyPlus,
    String? sampler,
    String? noiseSchedule,
    String? seed,
    int? animaSteps,
    double? animaCfg,
    String? animaSampler,
    String? animaScheduler,
  }) {
    state = state.copyWith(
      params: state.params.copyWith(
        model: model,
        width: width,
        height: height,
        steps: steps,
        cfg: cfg,
        cfgRescale: cfgRescale,
        varietyPlus: varietyPlus,
        sampler: sampler,
        noiseSchedule: noiseSchedule,
        seed: seed,
        animaSteps: animaSteps,
        animaCfg: animaCfg,
        animaSampler: animaSampler,
        animaScheduler: animaScheduler,
      ),
    );
  }

  void setSize(int width, int height) => state = state.copyWith(
    params: state.params.copyWith(width: width, height: height),
  );

  /// 切模型;切到 Anima 档位时套用该档推荐采样参数(对齐 web applyAnimaTier)。
  void setModel(String model) {
    var p = state.params.copyWith(model: model);
    if (isAnimaModel(model)) {
      final d = animaTierDefaults(animaTierOf(model));
      p = p.copyWith(
        animaSteps: d.steps,
        animaCfg: d.cfg,
        animaSampler: d.sampler,
        animaScheduler: d.scheduler,
      );
    }
    state = state.copyWith(params: p);
  }

  void setLoop(LoopCount l) =>
      state = state.copyWith(params: state.params.copyWith(loop: l));

  // ---- 长按拖动排序(onReorderItem 语义:newIndex 已按移除后调整)----

  List<T> _reordered<T>(List<T> src, int oldIndex, int newIndex) {
    final l = [...src];
    l.insert(newIndex, l.removeAt(oldIndex));
    return l;
  }

  void reorderCharacters(int oldIndex, int newIndex) => state = state.copyWith(
    characters: _reordered(state.characters, oldIndex, newIndex),
  );

  void reorderVibes(int oldIndex, int newIndex) => state = state.copyWith(
    vibes: _reordered(state.vibes, oldIndex, newIndex),
  );

  void reorderCharRefs(int oldIndex, int newIndex) => state = state.copyWith(
    charRefs: _reordered(state.charRefs, oldIndex, newIndex),
  );

  void refreshAnlas() {
    // 占位:正式版调 NAI /user/subscription
    state = state.copyWith(anlas: state.anlas);
  }
}
