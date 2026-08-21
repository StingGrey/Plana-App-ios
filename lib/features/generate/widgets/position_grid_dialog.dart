import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../gallery/gallery_state.dart';
import '../char_position.dart';
import '../generate_state.dart';
import '../models.dart';

/// 角色定位弹窗(对齐 web `CharacterPositionModal`)。
///
/// · V5(NAI 5)自由画布:按当前出图横竖比例占位,点哪放哪;主页当前图与出图
///   比例一致时直接拿它当画布,在真实构图上摆位更直观。
/// · V4/V4.5:5×5 网格(画布表达不了网格档位语义)。
/// 二者共享:顶部角色条一处切换多个角色、先选后确认(改动落草稿,确认才写回)。
Future<void> showPositionGridDialog(BuildContext context, String charId) {
  return showDialog(
    context: context,
    builder: (context) => _PositionDialog(initialCharId: charId),
  );
}

class _PositionDialog extends ConsumerStatefulWidget {
  const _PositionDialog({required this.initialCharId});

  final String initialCharId;

  @override
  ConsumerState<_PositionDialog> createState() => _PositionDialogState();
}

class _PositionDialogState extends ConsumerState<_PositionDialog> {
  late String _selectedId = widget.initialCharId;
  // 本地草稿:先改草稿,确认才写回;切换角色时保留各自未保存的改动。
  late final Map<String, String?> _draft = {
    for (final c in ref.read(generateProvider).characters) c.id: c.position,
  };

  /// 挂在切换条当前选中那颗 chip 上,打开时把它滚进视野。
  final _selectedChipKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedChipKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: .5);
      }
    });
  }

  void _setPos(String? pos) => setState(() => _draft[_selectedId] = pos);

  void _confirm() {
    final notifier = ref.read(generateProvider.notifier);
    final current = {
      for (final c in ref.read(generateProvider).characters) c.id: c.position,
    };
    _draft.forEach((id, pos) {
      if (current.containsKey(id) && current[id] != pos) {
        notifier.updateCharacter(id, position: pos);
      }
    });
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final gen = ref.watch(generateProvider);
    final chars = gen.characters;
    final params = gen.params;
    final isV5 = isNai5Model(params.model);
    final selName = chars
        .firstWhere(
          (c) => c.id == _selectedId,
          orElse: () => chars.isNotEmpty ? chars.first : _placeholder,
        )
        .name;

    // 主页当前图:比例与出图设置一致时当画布底图
    final sel = ref.watch(galleryProvider).selected;
    final showBg =
        isV5 &&
        sel != null &&
        aspectRatiosMatch(sel.width, sel.height, params.width, params.height);
    final Uint8List? bgBytes = showBg
        ? (sel.bytes ?? ref.watch(galleryImageProvider(sel.id)).value)
        : null;

    return Dialog(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 头部
                Row(
                  children: [
                    Icon(Icons.place_outlined, size: 19, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '设置角色位置',
                        style: context.texts.titleMedium!.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                      color: scheme.onSurfaceVariant,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 角色切换条:一处切换所有角色,无需反复开关弹窗。
                // 单行横滑而不是 Wrap 竖排:V5 一图最多 32 个角色,竖排能占掉
                // 半屏,把真正要操作的定位画布挤到画面外;打开时把当前角色滚进
                // 视野(之后都是用户手点,点得到的本来就在视野里,不再自动滚)。
                SizedBox(
                  height: 34,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: chars.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) => Center(
                      child: KeyedSubtree(
                        key: chars[i].id == _selectedId
                            ? _selectedChipKey
                            : null,
                        child: _switcherChip(context, chars[i], i),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 定位区
                if (isV5)
                  _canvas(context, chars, params, bgBytes)
                else
                  _grid(context, chars),
                const SizedBox(height: 14),
                // AUTO(当前角色置为自动)
                OutlinedButton.icon(
                  onPressed: () => _setPos(null),
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: Text('$selName · 自动 (AUTO)'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                    foregroundColor: _draft[_selectedId] == null
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(21),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // 取消 / 确认保存
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(23),
                          ),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      // 不带勾图标:对半分的窄屏半宽装不下「图标+四个字」,
                      // 文本会折成两行 —— 确认键的身份由填充色说明,图标是冗余。
                      child: FilledButton(
                        onPressed: _confirm,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(23),
                          ),
                        ),
                        child: const Text(
                          '确认保存',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const _placeholder = CharacterPrompt(id: '', name: '');

  Widget _switcherChip(BuildContext context, CharacterPrompt c, int index) {
    final scheme = context.scheme;
    final active = c.id == _selectedId;
    return Material(
      color: active ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _selectedId = c.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: active ? scheme.primary : scheme.outlineVariant,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                c.name,
                style: context.texts.labelMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: active
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                positionChipLabel(_draft[c.id]),
                style: context.texts.labelSmall!.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: (active
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant)
                      .withValues(alpha: .7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// V5 自由画布:按出图比例占位,可选底图,点哪放哪,画出所有角色的点。
  Widget _canvas(
    BuildContext context,
    List<CharacterPrompt> chars,
    GenParams params,
    Uint8List? bgBytes,
  ) {
    final scheme = context.scheme;
    final ratio = params.width / params.height;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        var w = constraints.maxWidth;
        var h = w / ratio;
        const maxH = 320.0;
        if (h > maxH) {
          h = maxH;
          w = h * ratio;
        }
        return Column(
          children: [
            Center(
              child: SizedBox(
                width: w,
                height: h,
                child: GestureDetector(
                  onTapDown: (d) {
                    final x = (d.localPosition.dx / w).clamp(0.0, 1.0);
                    final y = (d.localPosition.dy / h).clamp(0.0, 1.0);
                    _setPos(formatFreeformPosition(x, y));
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ColoredBox(color: scheme.surfaceContainerHigh),
                        ),
                        // 底图:主页当前图(比例一致)+ 轻压暗保证点/线可辨
                        if (bgBytes != null) ...[
                          Positioned.fill(
                            child: Image.memory(bgBytes, fit: BoxFit.cover),
                          ),
                          Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: .2),
                            ),
                          ),
                        ],
                        // 参考网格线(仅视觉辅助,不吸附)
                        for (final f in const [.2, .4, .6, .8]) ...[
                          Positioned(
                            left: w * f,
                            top: 0,
                            bottom: 0,
                            child: Container(
                              width: 1,
                              color: scheme.outline.withValues(alpha: .25),
                            ),
                          ),
                          Positioned(
                            top: h * f,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 1,
                              color: scheme.outline.withValues(alpha: .25),
                            ),
                          ),
                        ],
                        // 各角色的点,当前编辑的高亮放大
                        for (var i = 0; i < chars.length; i++)
                          ..._dot(context, chars[i], i, w, h),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${params.width}×${params.height} · 点击画布放置当前角色',
              style: context.texts.labelSmall!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _dot(
    BuildContext context,
    CharacterPrompt c,
    int index,
    double w,
    double h,
  ) {
    final ctr = resolveCharacterCenter(_draft[c.id]);
    if (ctr == null) return const [];
    final scheme = context.scheme;
    final cur = c.id == _selectedId;
    final d = cur ? 30.0 : 26.0;
    return [
      Positioned(
        left: ctr.x * w - d / 2,
        top: ctr.y * h - d / 2,
        child: IgnorePointer(
          child: Container(
            width: d,
            height: d,
            decoration: BoxDecoration(
              color: cur ? scheme.primary : scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: cur
                  ? Border.all(color: Colors.white, width: 2)
                  : Border.all(color: scheme.outline.withValues(alpha: .5)),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 3),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: cur ? 13 : 11,
                fontWeight: FontWeight.w700,
                color: cur ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    ];
  }

  /// V4/V4.5 的 5×5 网格(草稿驱动:当前角色高亮,其他角色占格灰显序号)。
  Widget _grid(BuildContext context, List<CharacterPrompt> chars) {
    final scheme = context.scheme;
    final myIndex = chars.indexWhere((c) => c.id == _selectedId) + 1;
    final occ = <String, List<int>>{};
    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      final p = _draft[c.id];
      if (c.id != _selectedId && p != null && RegExp(r'^[A-E][1-5]$').hasMatch(p)) {
        (occ[p] ??= []).add(i + 1);
      }
    }
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 26),
            for (final col in 'ABCDE'.split(''))
              Expanded(
                child: Center(
                  child: Text(
                    col,
                    style: context.texts.labelSmall!.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (var row = 1; row <= 5; row++) ...[
          Row(
            children: [
              SizedBox(
                width: 26,
                child: Center(
                  child: Text(
                    '$row',
                    style: context.texts.labelSmall!.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              for (final col in 'ABCDE'.split(''))
                Expanded(child: _cell(context, '$col$row', myIndex, occ)),
            ],
          ),
          if (row < 5) const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _cell(
    BuildContext context,
    String code,
    int myIndex,
    Map<String, List<int>> occ,
  ) {
    final scheme = context.scheme;
    final mine = _draft[_selectedId] == code;
    final others = occ[code] ?? const <int>[];
    final all = [if (mine) myIndex, ...others]..sort();
    final stacked = all.length >= 2;

    late final Color bg;
    Border? border;
    Widget? content;

    if (stacked) {
      bg = scheme.tertiaryContainer;
      if (mine) border = Border.all(color: scheme.primary, width: 2);
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers, size: 13, color: scheme.onTertiaryContainer),
          const SizedBox(height: 1),
          Text(
            all.join('·'),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: scheme.onTertiaryContainer,
            ),
          ),
        ],
      );
    } else if (mine) {
      bg = scheme.primary;
      content = Text(
        '$myIndex',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimary,
        ),
      );
    } else if (others.length == 1) {
      bg = scheme.surfaceContainerHighest;
      border = Border.all(color: scheme.outline.withValues(alpha: .4));
      content = Text(
        '${others.first}',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
        ),
      );
    } else {
      bg = scheme.surfaceContainerHigh;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: AspectRatio(
        aspectRatio: 1,
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.standard,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(9),
            border: border,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _setPos(mine ? null : code),
              child: Center(child: content),
            ),
          ),
        ),
      ),
    );
  }
}
