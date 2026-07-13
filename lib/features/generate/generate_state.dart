import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';

final generateProvider =
    NotifierProvider<GenerateNotifier, GenerateState>(GenerateNotifier.new);

class GenerateNotifier extends Notifier<GenerateState> {
  int _idSeq = 100;

  @override
  GenerateState build() => GenerateState.initial();

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
                    enabled: enabled,
                    activeTab: activeTab,
                  )
                : c.copyWith(
                    name: name,
                    positive: positive,
                    negative: negative,
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

  void moveCharacter(String id, int delta) {
    final list = [...state.characters];
    final i = list.indexWhere((c) => c.id == id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= list.length) return;
    final c = list.removeAt(i);
    list.insert(j, c);
    state = state.copyWith(characters: list);
  }

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
    state = state.copyWith(vibes: state.vibes.where((v) => v.id != id).toList());
  }

  void setVibeEnabled(String id, bool enabled) {
    state = state.copyWith(
      vibes: [
        for (final v in state.vibes)
          if (v.id == id) v.copyWith(enabled: enabled) else v,
      ],
    );
  }

  /// 整体替换 vibe 列表(Vibe 管理器「取消」还原进入前快照用)。
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
    );
    openPanel(Panel.charRef);
    return id;
  }

  void updateCharRef(String id,
      {CharRefMode? mode, double? strength, double? infoExtracted}) {
    state = state.copyWith(
      charRefs: [
        for (final r in state.charRefs)
          if (r.id == id)
            r.copyWith(mode: mode, strength: strength, infoExtracted: infoExtracted)
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
    );
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
    state = state.copyWith(img2img: cur.copyWith(strength: strength, noise: noise));
  }

  void disableImg2Img() => state = state.copyWith(img2img: null);

  // ---- 提示词(编辑器保存回写) ----
  void setPrompts({String? positive, String? negative}) {
    state = state.copyWith(prompt: positive, negativePrompt: negative);
  }

  // ---- 参数 ----
  void applyParams(GenParams params) => state = state.copyWith(params: params);

  void setSize(int width, int height) =>
      state = state.copyWith(params: state.params.copyWith(width: width, height: height));

  void setModel(String model) =>
      state = state.copyWith(params: state.params.copyWith(model: model));

  void setLoop(LoopCount l) =>
      state = state.copyWith(params: state.params.copyWith(loop: l));

  // ---- 长按拖动排序(onReorderItem 语义:newIndex 已按移除后调整)----

  List<T> _reordered<T>(List<T> src, int oldIndex, int newIndex) {
    final l = [...src];
    l.insert(newIndex, l.removeAt(oldIndex));
    return l;
  }

  void reorderCharacters(int oldIndex, int newIndex) => state = state.copyWith(
      characters: _reordered(state.characters, oldIndex, newIndex));

  void reorderVibes(int oldIndex, int newIndex) =>
      state = state.copyWith(vibes: _reordered(state.vibes, oldIndex, newIndex));

  void reorderCharRefs(int oldIndex, int newIndex) => state = state.copyWith(
      charRefs: _reordered(state.charRefs, oldIndex, newIndex));

  void refreshAnlas() {
    // 占位:正式版调 NAI /user/subscription
    state = state.copyWith(anlas: state.anlas);
  }
}
