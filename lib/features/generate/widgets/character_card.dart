import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../editor/editor_page.dart';
import '../generate_state.dart';
import '../models.dart';
import 'common.dart';
import 'position_grid_dialog.dart';
import 'section_card.dart';

/// 角色面板(定稿版):每个角色一张内嵌圆角小卡。
/// 行 1:电源开关 · 名称(+状态说明)· 站位徽章 · 删除
/// 行 2:提示词单行预览 + token 计数
class CharacterCard extends ConsumerWidget {
  const CharacterCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    final chars = state.characters;
    final canAdd = chars.length < 6;

    return SectionCard(
      icon: Icons.group_outlined,
      title: '角色',
      badge: CountBadge('${chars.length} / 6'),
      actions: [
        if (chars.isNotEmpty)
          RoundIconBtn(
            Icons.delete_sweep_outlined,
            tooltip: '清空全部角色',
            color: scheme.onSurfaceVariant,
            onTap: () => _confirmClear(context, notifier),
          ),
        RoundIconBtn(
          Icons.add,
          tooltip: '添加角色',
          color: canAdd ? null : scheme.outline,
          onTap: canAdd ? notifier.addCharacter : null,
        ),
      ],
      expanded: state.openPanels.contains(Panel.characters),
      onHeaderTap: () => notifier.togglePanel(Panel.characters),
      body: chars.isEmpty
          ? const InfoNote('还没有角色。多角色可分别设置提示词与画面站位(最多 6 个)。')
          // 长按卡片拖动排序;横滑删除保留
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
                    child: SwipeToDelete(
                      itemKey: ValueKey('dismiss${chars[i].id}'),
                      onDelete: () => notifier.removeCharacter(chars[i].id),
                      child: _CharacterTile(char: chars[i]),
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _confirmClear(
      BuildContext context, GenerateNotifier notifier) async {
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
  const _CharacterTile({required this.char});

  final CharacterPrompt char;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    final enabled = char.enabled;
    final tokens = (char.positive.length / 2.2).round();

    return AnimatedOpacity(
      duration: Motion.fast,
      opacity: enabled ? 1 : .5,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(sharedAxisRoute(
            EditorPage(positive: true, characterName: char.name),
          )),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    // 电源开关(裸图标)
                    IconButton(
                      onPressed: () =>
                          notifier.updateCharacter(char.id, enabled: !enabled),
                      icon: Icon(Icons.power_settings_new,
                          size: 21,
                          color: enabled ? scheme.tertiary : scheme.outline),
                      tooltip: enabled ? '停用(保留配置)' : '启用',
                      visualDensity:
                          const VisualDensity(horizontal: -3, vertical: -3),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                    ),
                    const SizedBox(width: 4),
                    // 名称 + 状态说明:占满中间,把尾部(徽章+删除)顶到最右
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              char.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.bodyLarge!.copyWith(
                                fontWeight: FontWeight.w700,
                                color:
                                    enabled ? scheme.onSurface : scheme.outline,
                              ),
                            ),
                          ),
                          if (!enabled) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '已禁用 · 配置保留',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.texts.labelSmall!
                                    .copyWith(color: scheme.outline),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 站位徽章
                    Material(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(17),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => showPositionGridDialog(context, char.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.grid_on,
                                  size: 15,
                                  color: char.position == null
                                      ? scheme.onSurfaceVariant
                                      : scheme.primary),
                              const SizedBox(width: 5),
                              SizedBox(
                                width: 38,
                                child: Text(
                                  char.position ?? 'AUTO',
                                  textAlign: TextAlign.center,
                                  style: mono(context,
                                          size: 12, weight: FontWeight.w700)
                                      .copyWith(
                                          color: char.position == null
                                              ? scheme.onSurfaceVariant
                                              : scheme.primary),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: IconButton(
                        onPressed: () => notifier.removeCharacter(char.id),
                        icon: Icon(Icons.delete_outline,
                            size: 20,
                            color: scheme.error.withValues(alpha: .85)),
                        tooltip: '删除角色',
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          char.positive.isEmpty
                              ? '点击编辑提示词…'
                              : char.positive,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodyMedium!.copyWith(
                            color: char.positive.isEmpty
                                ? scheme.outline
                                : (enabled
                                    ? scheme.onSurfaceVariant
                                    : scheme.outline),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$tokens',
                        style: mono(context, size: 11, weight: FontWeight.w500)
                            .copyWith(color: scheme.outline),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
