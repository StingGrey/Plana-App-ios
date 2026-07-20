import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_theme.dart';
import '../../vibe_library/vibe_library.dart';
import '../../vibe_library/vibe_library_page.dart';
import '../generate_state.dart';
import '../models.dart';
import 'common.dart';
import 'section_card.dart';

/// 顶层函数:在后台 isolate 算图片内容哈希(sha256 hex),避免大图卡主线程。
String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

/// Vibe Transfer 卡:缩略图横条(可选)+ 虚线添加格,
/// 下方只显示当前选中那张的详情(参考图名 · 移除 · Strength / Info Extracted)。
class VibeCard extends ConsumerStatefulWidget {
  const VibeCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  ConsumerState<VibeCard> createState() => _VibeCardState();
}

class _VibeCardState extends ConsumerState<VibeCard> {
  String? _selectedId;

  Future<void> _onAdd() async {
    final XFile? file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    final hash = await compute(_sha256Hex, bytes); // 后台算内容哈希
    if (!mounted) return;
    final name = file.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    // 顺手入库(同图去重;重启后可从 Vibe 库找回,编码缓存互通不多扣点)
    String? sourceId;
    try {
      final entry = await ref
          .read(vibeLibraryProvider.notifier)
          .importImageBytes(bytes, name, knownHash: hash);
      sourceId = entry.id;
    } catch (_) {
      // 入库失败不影响本次使用
    }
    if (!mounted) return;
    final hadCharRefs = ref.read(generateProvider).enabledCharRefs > 0;
    final id = ref
        .read(generateProvider.notifier)
        .addVibe(image: bytes, name: name, imageHash: hash, sourceId: sourceId);
    if (id.isNotEmpty) {
      if (hadCharRefs) _mutexHint();
      setState(() => _selectedId = id);
    }
  }

  void _toggle(String id, bool currentlyEnabled) {
    final hadCharRefs = ref.read(generateProvider).enabledCharRefs > 0;
    ref.read(generateProvider.notifier).setVibeEnabled(id, !currentlyEnabled);
    if (!currentlyEnabled && hadCharRefs) _mutexHint();
  }

  /// 互斥切换提示:启用/加入 Vibe 导致角色参考被暂停时,弹一次 toast。
  void _mutexHint() =>
      hintSnack(context, '与角色参考互斥,已暂停角色参考', icon: Icons.swap_horiz);

  /// 删除某张,并把选中态平移到相邻项
  void _removeVibe(String id) {
    final vibes = ref.read(generateProvider).vibes;
    final idx = vibes.indexWhere((v) => v.id == id);
    ref.read(generateProvider.notifier).removeVibe(id);
    final rest = ref.read(generateProvider).vibes;
    setState(() {
      if (rest.isEmpty) {
        _selectedId = null;
      } else if (id == _selectedId) {
        _selectedId = rest[idx.clamp(0, rest.length - 1)].id;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;

    final vibes = state.vibes;
    // 无内容时恒收起;头部「+」导入后(addVibe 会 openPanel)自动展开。
    final expanded = state.openPanels.contains(Panel.vibe) && vibes.isNotEmpty;

    VibeItem? selected;
    for (final v in vibes) {
      if (v.id == _selectedId) {
        selected = v;
        break;
      }
    }
    selected ??= vibes.isNotEmpty ? vibes.first : null;

    return SectionCard(
      icon: Icons.palette_outlined,
      title: 'Vibe Transfer',
      reorderIndex: widget.reorderIndex,
      badge: vibes.isEmpty ? null : CountBadge('${vibes.length}'),
      actions: [
        RoundIconBtn(
          Icons.grid_view,
          tooltip: 'Vibe 库',
          color: scheme.onSurfaceVariant,
          onTap: () => Navigator.of(
            context,
          ).push(sharedAxisRoute(const VibeLibraryPage())),
        ),
        RoundIconBtn(
          Icons.add,
          tooltip: '导入参考图',
          color: scheme.primary,
          onTap: _onAdd,
        ),
      ],
      expanded: expanded,
      onHeaderTap: () => notifier.togglePanel(Panel.vibe),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 72,
            // 长按缩略图拖动排序(参考顺序即下发顺序)
            child: ReorderableListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 2),
              proxyDecorator: dragProxy,
              onReorderStart: dragStartHaptic,
              onReorderEnd: dragEndHaptic,
              onReorderItem: notifier.reorderVibes,
              children: [
                for (final v in vibes)
                  Padding(
                    key: ValueKey(v.id),
                    padding: const EdgeInsets.only(right: 10),
                    child: RefThumb(
                      selected: v.id == selected?.id,
                      enabled: v.enabled,
                      image: v.image,
                      onTap: () => setState(() => _selectedId = v.id),
                    ),
                  ),
              ],
            ),
          ),
          if (selected != null) ...[
            const SizedBox(height: 14),
            _VibeDetail(
              vibe: selected,
              index: vibes.indexOf(selected) + 1,
              onRemove: () => _removeVibe(selected!.id),
              onToggle: () => _toggle(selected!.id, selected.enabled),
            ),
          ],
        ],
      ),
    );
  }
}

/// 选中项详情
class _VibeDetail extends ConsumerWidget {
  const _VibeDetail({
    required this.vibe,
    required this.index,
    required this.onRemove,
    required this.onToggle,
  });

  final VibeItem vibe;
  final int index;
  final VoidCallback onRemove;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(generateProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RefDetailHeader(
          index: index,
          name: vibe.name,
          onRemove: onRemove,
          enableToggle: RefEnableToggle(enabled: vibe.enabled, onTap: onToggle),
        ),
        const SizedBox(height: 14),
        LiveParamSlider(
          label: 'Strength 参考强度',
          value: vibe.strength,
          divisions: 100, // step 0.01(对齐 web)
          onCommit: (v) => notifier.updateVibe(vibe.id, strength: v),
        ),
        const SizedBox(height: 6),
        if (vibe.isEncodingOnly)
          // 纯编码 vibe(库导入、无原图):IE 随编码固定,不可调
          IgnorePointer(
            child: Opacity(
              opacity: 0.5,
              child: ParamSlider(
                label: 'Info Extracted 信息提取(随编码固定)',
                value: vibe.infoExtracted,
                divisions: 100,
                onChanged: (_) {},
              ),
            ),
          )
        else
          LiveParamSlider(
            label: 'Info Extracted 信息提取',
            value: vibe.infoExtracted,
            divisions: 100,
            onCommit: (v) => notifier.updateVibe(vibe.id, infoExtracted: v),
          ),
      ],
    );
  }
}
