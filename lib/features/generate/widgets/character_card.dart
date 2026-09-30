import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/nai_tokenizer.dart';
import '../../editor/editor_page.dart';
import '../../inspiration/widgets/char_pick_sheet.dart';
import '../../inspiration/widgets/tag_card.dart' show TagCardPreview;
import '../char_position.dart';
import '../generate_state.dart';
import '../models.dart';
import 'common.dart';
import 'position_grid_dialog.dart';
import 'prompt_card.dart' show negativePreview;
import 'section_card.dart';

/// 角色面板:每个角色一张内嵌圆角小卡。
/// 左:头像位(库里选来的显示预览图,否则灰底人像图标;点它从灵感角色库换人)
/// 右行 1:名称(点名字改名)· 站位徽章 · 电源开关 · 删除
/// 右下:正向预览 + token 计数;写了负面再跟一行负面(与提示词卡同写法)
class CharacterCard extends ConsumerWidget {
  const CharacterCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    final chars = state.characters;
    final cap = maxCharactersOf(state.params.model);
    final canAdd = chars.length < cap;
    // 读数按**启用**数算:上限管的是进载荷的那几个,停用的不占额度。切模型时
    // 超出的尾巴会自动停用(见 GenerateNotifier._capEnabled),之后还标红就只剩
    // 一种来路 —— 用户在小槽位模型下自己又勾回来了,那确实该红。
    final active = chars.where((c) => c.enabled).length;

    return SectionCard(
      icon: Icons.group_outlined,
      title: '角色',
      reorderIndex: reorderIndex,
      badge: CountBadge('$active / $cap', error: active > cap),
      actions: [
        if (chars.isNotEmpty)
          RoundIconBtn(
            Icons.delete_sweep_outlined,
            tooltip: '清空全部角色',
            color: scheme.onSurfaceVariant,
            onTap: () => _confirmClear(context, notifier),
          ),
        // 与 Vibe / 角色参考卡头的「库」同一枚图标、同一个位置
        RoundIconBtn(
          Icons.grid_view,
          tooltip: '角色库',
          color: canAdd ? scheme.onSurfaceVariant : scheme.outline,
          onTap: canAdd ? () => _addFromLibrary(context, ref) : null,
        ),
        RoundIconBtn(
          Icons.add,
          tooltip: '添加角色',
          color: canAdd ? null : scheme.outline,
          onTap: canAdd ? notifier.addCharacter : null,
        ),
      ],
      // 没有角色时整卡不可展开(展开体本就是空的),但保留一个静态 chevron 占位,
      // 让空卡卡头与下方各功能卡视觉对齐;箭头不接手势、不旋转、不点开空白。
      expanded: chars.isNotEmpty && state.openPanels.contains(Panel.characters),
      onHeaderTap: chars.isEmpty
          ? null
          : () => notifier.togglePanel(Panel.characters),
      chevronPlaceholder: chars.isEmpty,
      body: chars.isEmpty
          ? null
          // 长按卡片拖动排序。删除只走行内那枚按钮 —— 横滑抹掉的是整份角色配置
          // (提示词/站位/开关),而这里没有撤销可给。
          : ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              proxyDecorator: dragProxy,
              onReorderStart: dragStartHaptic,
              onReorderEnd: dragEndHaptic,
              onReorderItem: notifier.reorderCharacters,
              children: [
                for (var i = 0; i < chars.length; i++)
                  Padding(
                    key: ValueKey('char${chars[i].id}'),
                    padding: EdgeInsets.only(top: i > 0 ? 9 : 0),
                    child: _CharacterTile(char: chars[i], index: i),
                  ),
              ],
            ),
    );
  }

  /// 卡头「角色库」:多选追加,可选数 = 剩下的槽位(只剩一个就是点一下即加)。
  Future<void> _addFromLibrary(BuildContext context, WidgetRef ref) async {
    final s = ref.read(generateProvider);
    final room = maxCharactersOf(s.params.model) - s.characters.length;
    if (room <= 0) return;
    final picked = await showCharPickSheet(context, max: room);
    if (picked == null || picked.isEmpty || !context.mounted) return;
    ref.read(generateProvider.notifier).addNamedCharactersFrom([
      for (final p in picked)
        (
          name: p.entry.name,
          positive: p.entry.positive,
          negative: p.entry.negative,
          avatar: p.preview,
        ),
    ]);
  }

  Future<void> _confirmClear(
    BuildContext context,
    GenerateNotifier notifier,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部角色?'),
        content: const Text('将移除所有角色及其配置,此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: context.scheme.error,
              foregroundColor: context.scheme.onError,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) notifier.clearCharacters();
  }
}

class _CharacterTile extends ConsumerWidget {
  const _CharacterTile({required this.char, required this.index});

  final CharacterPrompt char;

  /// 行序,只用来算改名留空时回落的默认名。
  final int index;

  /// 点名字改名。留空 = 回到默认的「角色 N」,N 按当前行序算,与新增时同一口径
  /// (名字本就不是稳定句柄,认人靠 id)。
  ///
  /// 名字只在 app 内显示:载荷里没有这一项,导入也读不回来,所以改名不影响出图,
  /// 也不必跟着图走。
  Future<void> _rename(BuildContext context, GenerateNotifier notifier) async {
    final fallback = '角色 ${index + 1}';
    final ctrl = TextEditingController(text: char.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            isDense: true,
            hintText: fallback, // 留空就按默认编号显示
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null) return; // 取消
    final trimmed = name.trim();
    notifier.updateCharacter(
      char.id,
      name: trimmed.isEmpty ? fallback : trimmed,
    );
  }

  /// 点头像:从灵感角色库挑一个换进这张卡(名字、正负向、头像;站位和开关不动)。
  Future<void> _pickFromLibrary(BuildContext context, WidgetRef ref) async {
    final picked = await showCharPickSheet(context);
    if (picked == null || picked.isEmpty || !context.mounted) return;
    final p = picked.first;
    // 读最新的:面板开着的这段时间里,这张卡可能被改过,甚至被删了
    final cur = ref
        .read(generateProvider)
        .characters
        .where((c) => c.id == char.id)
        .firstOrNull;
    if (cur == null) return;
    // 没头像又写了字 = 手写的内容,换之前问一句,别一下冲掉。带头像的本就是
    // 库里选来的,点头像就是要换人,不再多问。
    if (cur.avatar == null &&
        (cur.positive.trim().isNotEmpty || cur.negative.trim().isNotEmpty)) {
      final ok = await confirmDialog(
        context,
        title: '替换「${cur.name}」?',
        message: '提示词将换成「${p.entry.name}」的。',
        confirmLabel: '替换',
      );
      if (!ok || !context.mounted) return;
    }
    ref
        .read(generateProvider.notifier)
        .fillCharacterFrom(
          char.id,
          name: p.entry.name,
          positive: p.entry.positive,
          negative: p.entry.negative,
          avatar: p.preview,
        );
  }

  void _openEditor(BuildContext context, {required bool positive}) =>
      Navigator.of(
        context,
      ).push(sharedAxisRoute(EditorPage(positive: positive, charId: char.id)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    final enabled = char.enabled;
    // 只有站位徽章的写法跟模型走(见下),select 一下别让整张卡跟着全局状态重建。
    final isV5 = ref.watch(
      generateProvider.select((s) => isNai5Model(s.params.model)),
    );
    // AUTO 是整张图的档(官方 AI's Choice = use_coords false),不是这张卡的属性:
    // 坐标一直在,只是模型不理会。同样 select 一下,别让整张卡跟着全局重建。
    final autoPos = ref.watch(
      generateProvider.select((s) => !s.params.useCoords),
    );
    final tokenizer = ref.watch(naiTokenizerProvider).value;
    final hasNeg = char.negative.trim().isNotEmpty;
    // 停用只灰掉头像和文字,电源键保持清晰 —— 它是把角色叫回来的唯一入口
    final posColor = !enabled
        ? scheme.outline
        : (autoPos ? scheme.onSurfaceVariant : scheme.primary);
    final negColor = enabled ? scheme.error : scheme.outline;
    final promptStyle = context.texts.bodyMedium!;
    final countStyle = mono(
      context,
      size: 11,
      weight: FontWeight.w500,
    ).copyWith(color: scheme.outline);

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openEditor(context, positive: true),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
          // 卡高由头像定,文字块在它旁边垂直居中:空卡、短提示词的卡也和别的
          // 卡一样高,不会在底下空出一截
          child: Row(
            children: [
              _Avatar(
                url: char.avatar,
                name: char.name,
                enabled: enabled,
                onTap: () => _pickFromLibrary(context, ref),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        // 名称占满中间,把尾部(徽章 + 开关 + 删除)顶到最右
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                // 点名字改名:热区只包名字本身,外层那圈照旧点开
                                // 编辑器(里层先拿到这一下)。长按是整卡拖排序,
                                // 这里不接。
                                child: InkWell(
                                  onTap: () => _rename(context, notifier),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Text(
                                      char.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: context.texts.bodyLarge!.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: enabled
                                            ? scheme.onSurface
                                            : scheme.outline,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        _PositionChip(
                          // AUTO 是整张图的档(use_coords=false):这时坐标还在,
                          // 只是模型不理会,徽章统一写 AUTO。否则网格模型
                          // (V4/V4.5)下显示它实际会被吸附到的那一格 —— 徽章写
                          // '42,67%'、请求里发的却是 C4 的格心,两边对不上
                          // (见 quantizeCenterToGrid)。
                          label: autoPos
                              ? 'AUTO'
                              : positionChipLabel(char.position, grid: !isV5),
                          color: posColor,
                          onTap: () => showPositionGridDialog(context, char.id),
                        ),
                        const SizedBox(width: 4),
                        RefEnableToggle(
                          enabled: enabled,
                          onTap: () => notifier.updateCharacter(
                            char.id,
                            enabled: !enabled,
                          ),
                          onTooltip: '停用(保留配置)',
                        ),
                        SizedBox(
                          width: 36,
                          height: 38,
                          child: IconButton(
                            onPressed: () => notifier.removeCharacter(char.id),
                            icon: Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: scheme.error.withValues(alpha: .85),
                            ),
                            tooltip: '删除角色',
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // 正向:没写负面时给两行;写了负面就一行,底下跟一行负面
                    // (与提示词卡同一种写法)。空卡不标计数。
                    Padding(
                      padding: const EdgeInsets.only(left: 4, right: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text(
                              char.positive.isEmpty
                                  ? '点击编辑提示词…'
                                  : char.positive,
                              maxLines: hasNeg ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: promptStyle.copyWith(
                                color: char.positive.isEmpty || !enabled
                                    ? scheme.outline
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (char.positive.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              '${totalPromptTokens(tokenizer, main: char.positive)}',
                              style: countStyle,
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (hasNeg)
                      InkWell(
                        onTap: () => _openEditor(context, positive: false),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4, right: 6),
                          child: Row(
                            children: [
                              Icon(Icons.block, size: 15, color: negColor),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  negativePreview(char.negative),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: promptStyle.copyWith(color: negColor),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${totalPromptTokens(tokenizer, main: char.negative)}',
                                style: countStyle,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 站位徽章:点开站位网格。宽度随字走(C3 / AUTO / 42,67%),给名字多留地方。
class _PositionChip extends StatelessWidget {
  const _PositionChip({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(17),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_on, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: mono(
                  context,
                  size: 12,
                  weight: FontWeight.w700,
                ).copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 停用时头像去色。
const _greyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0,
]);

/// 头像位:库里选来的角色显示它的预览图(比例同灵感库角色图 832:1216);
/// 没有就是灰底人像图标(与站位徽章同一个底色),图读不出来也退回它。
/// 点它从灵感角色库挑人。
class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.url,
    required this.name,
    required this.enabled,
    required this.onTap,
  });

  final String? url;
  final String name;
  final bool enabled;
  final VoidCallback onTap;

  static const _w = 55.0, _h = 80.0;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final slot = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.person_search_outlined,
          size: 24,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    Widget child = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url == null
          ? slot
          : TagCardPreview(
              url: url,
              name: name,
              decodeWidth: _w,
              placeholder: slot,
            ),
    );
    if (!enabled) {
      child = Opacity(
        opacity: .55,
        child: ColorFiltered(colorFilter: _greyscale, child: child),
      );
    }
    return Tooltip(
      message: url == null ? '从角色库选' : '换角色',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(width: _w, height: _h, child: child),
      ),
    );
  }
}
