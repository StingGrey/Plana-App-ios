import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/bot_session_store.dart';
import '../../../core/net/backend_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/selection_bar.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../../shell/shell_state.dart';
import '../public_tags.dart';
import '../tag_library.dart';
import '../tag_models.dart';
import 'scope_seg_tabs.dart';
import 'tag_card.dart';
import 'tag_sheets.dart';

/// 选中的一个角色:条目 + 它该显示的预览(按 publicId 补过,见 [tagPreviewOf])。
typedef PickedChar = ({TagEntry entry, String? preview});

/// 从灵感角色库选角色 —— 角色卡的头像、角色卡头的「角色库」共用。
/// 形态照相册「移动到」那张面板:标题 + 封面卡网格,卡片就是灵感页那种竖版封面卡。
///
/// [max] 为 1:点一张即选定并关闭,卡上不画选择圈(给单张角色卡换人)。
/// 大于 1:点卡勾选,底栏「加入角色」确认,最多 [max] 个。取消返回 null。
Future<List<PickedChar>?> showCharPickSheet(
  BuildContext context, {
  int max = 1,
}) => showModalBottomSheet<List<PickedChar>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _CharPickSheet(max: max),
);

class _CharPickSheet extends ConsumerStatefulWidget {
  const _CharPickSheet({required this.max});

  final int max;

  @override
  ConsumerState<_CharPickSheet> createState() => _CharPickSheetState();
}

class _CharPickSheetState extends ConsumerState<_CharPickSheet>
    with SingleTickerProviderStateMixin {
  static const _cat = TagCategory.character;
  static const _cols = 3, _pad = 12.0, _gap = 8.0;

  late final TabController _tab = TabController(length: 2, vsync: this);
  String _search = '';

  /// 已勾选(多选时)。插入序即加入角色卡的顺序。
  final _picked = <String, PickedChar>{};

  bool get _multi => widget.max > 1;

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _tap(TagEntry e, String? preview) {
    if (!_multi) return _done([(entry: e, preview: preview)]);
    if (_picked.containsKey(e.id)) {
      setState(() => _picked.remove(e.id));
    } else if (_picked.length < widget.max) {
      setState(() => _picked[e.id] = (entry: e, preview: preview));
    } else {
      hintSnack(context, '最多选 ${widget.max} 个', icon: Icons.block_outlined);
    }
  }

  void _done(List<PickedChar> picked) {
    // 「最近使用」与灵感页确认时同一口径
    unawaited(
      ref.read(tagLibraryProvider.notifier).markUsed(_cat, [
        for (final p in picked) p.entry.id,
      ]),
    );
    Navigator.pop(context, picked);
  }

  bool _matches(TagEntry e, String q) {
    if (q.isEmpty) return true;
    bool has(String s) => s.toLowerCase().contains(q);
    return has(e.name) ||
        e.aliases.any(has) ||
        has(e.positive) ||
        e.tags.any(has);
  }

  /// 我的:自建 / 我发布的在前,收藏来的在后,组内最新在前(同灵感页)。
  List<TagEntry> _mineList(TagLibraryState lib, List<TagEntry>? pub) {
    final q = _search.trim().toLowerCase();
    final list = [
      for (final e in mergeMineTags(
        lib.of(_cat),
        ref.watch(botSessionProvider).value?.botUserId,
        pub,
      ))
        if (_matches(e, q)) e,
    ];
    int fav(TagEntry e) => e.origin == TagOrigin.favorited ? 1 : 0;
    list.sort((a, b) {
      final c = fav(a) - fav(b);
      return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  List<TagEntry> _publicList(List<TagEntry> all) {
    final q = _search.trim().toLowerCase();
    return [
      for (final e in all)
        if (_matches(e, q)) e,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final lib = ref.watch(tagLibraryProvider).value ?? const TagLibraryState();
    final pubAsync = ref.watch(publicTagsProvider(_cat));
    final pubPreview = publicPreviewsOf(pubAsync.value);
    return FractionallySizedBox(
      heightFactor: .85,
      child: Padding(
        // 搜索时键盘顶上来,底栏跟着上移,别被盖住
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择角色', style: context.texts.titleLarge),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _pad),
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tagCategoryDef(_cat).searchHint,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: scheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(_pad, 8, _pad, 8),
              child: ScopeSegTabs(
                controller: _tab,
                mineCount: lib.of(_cat).length,
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  _grid(
                    _mineList(lib, pubAsync.value),
                    pubPreview,
                    isPublic: false,
                    empty: _search.trim().isEmpty ? '还没有角色' : '没有匹配的角色',
                  ),
                  _publicTab(pubAsync, pubPreview),
                ],
              ),
            ),
            if (_multi)
              SelectionBar(
                visible: _picked.isNotEmpty,
                onClear: () => setState(_picked.clear),
                primary: FilledButton.icon(
                  onPressed: () => _done(_picked.values.toList()),
                  style: selectionPrimaryStyle(),
                  icon: const Icon(Icons.person_add_alt, size: 18),
                  label: Text('加入角色 (${_picked.length})'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _publicTab(
    AsyncValue<List<TagEntry>> async,
    Map<String, String> pubPreview,
  ) => async.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (e, _) {
      // 会话过期后端回 401/403,与无会话同样给「去授权」出口(同灵感页)
      final needBot =
          (e is StateError && e.message == 'need-bot') ||
          (e is BackendException && (e.status == 401 || e.status == 403));
      if (needBot) {
        return _empty(
          '公共库需要 Bot 授权',
          action: (
            '去授权',
            () {
              Navigator.pop(context);
              ref.read(shellIndexProvider.notifier).select(kTabProfile);
            },
          ),
        );
      }
      return _empty(
        '公共库加载失败',
        action: ('重试', () => ref.invalidate(publicTagsProvider(_cat))),
      );
    },
    data: (all) => _grid(
      _publicList(all),
      pubPreview,
      isPublic: true,
      empty: _search.trim().isEmpty ? '公共库暂无内容' : '没有匹配的角色',
    ),
  );

  Widget _grid(
    List<TagEntry> list,
    Map<String, String> pubPreview, {
    required bool isPublic,
    required String empty,
  }) {
    if (list.isEmpty) return _empty(empty);
    return LayoutBuilder(
      builder: (context, box) {
        final cellW = (box.maxWidth - _pad * 2 - _gap * (_cols - 1)) / _cols;
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
            _pad,
            4,
            _pad,
            16 + MediaQuery.paddingOf(context).bottom,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _cols,
            mainAxisSpacing: _gap,
            crossAxisSpacing: _gap,
            childAspectRatio: tagCategoryDef(_cat).previewAspect,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final e = list[i];
            final preview = tagPreviewOf(e, pubPreview);
            return TagCard(
              key: ValueKey(e.id),
              entry: e,
              previewUrl: preview,
              decodeWidth: cellW,
              selected: _picked.containsKey(e.id),
              isPublic: isPublic,
              showCheck: _multi,
              onTap: () => _tap(e, preview),
              onLongPress: () => showTagDetailSheet(context, e),
            );
          },
        );
      },
    );
  }

  Widget _empty(String text, {(String, VoidCallback)? action}) {
    final scheme = context.scheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_outline, size: 44, color: scheme.outlineVariant),
          const SizedBox(height: 10),
          Text(
            text,
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 10),
            FilledButton.tonal(onPressed: action.$2, child: Text(action.$1)),
          ],
        ],
      ),
    );
  }
}
