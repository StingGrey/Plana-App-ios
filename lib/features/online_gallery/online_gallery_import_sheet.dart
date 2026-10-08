import 'package:flutter/material.dart';

import 'online_gallery_models.dart';

Color galleryTagColor(OnlineGalleryTagCategory category, ColorScheme scheme) =>
    switch (category) {
      OnlineGalleryTagCategory.artist =>
        scheme.brightness == Brightness.dark
            ? const Color(0xFFFF9292)
            : const Color(0xFFAC2929),
      OnlineGalleryTagCategory.copyright =>
        scheme.brightness == Brightness.dark
            ? const Color(0xFFC49AFF)
            : const Color(0xFF7535AB),
      OnlineGalleryTagCategory.character =>
        scheme.brightness == Brightness.dark
            ? const Color(0xFF79CF65)
            : const Color(0xFF327326),
      OnlineGalleryTagCategory.general =>
        scheme.brightness == Brightness.dark
            ? const Color(0xFF67B8F5)
            : const Color(0xFF176CA5),
      OnlineGalleryTagCategory.meta =>
        scheme.brightness == Brightness.dark
            ? const Color(0xFFE9D078)
            : const Color(0xFF806300),
      OnlineGalleryTagCategory.unknown => scheme.onSurfaceVariant,
    };

class GalleryPromptImport {
  const GalleryPromptImport({this.positive, this.negative});
  final String? positive;
  final String? negative;
}

/// Null means leave that side of the generation prompt untouched.
class OnlineGalleryImportSheet extends StatefulWidget {
  const OnlineGalleryImportSheet({
    super.key,
    required this.item,
    required this.filter,
  });
  final OnlineGalleryItem item;
  final String Function(String) filter;

  @override
  State<OnlineGalleryImportSheet> createState() =>
      _OnlineGalleryImportSheetState();
}

class _OnlineGalleryImportSheetState extends State<OnlineGalleryImportSheet> {
  late final Set<String> _selected = widget.item.tags.toSet();
  late bool _useTags = widget.item.prompt.trim().isEmpty;
  bool _positive = true;
  bool _negative = false;

  String get _positiveText => widget.filter(
    _useTags
        ? widget.item.tags.where(_selected.contains).toSet().join(', ')
        : widget.item.prompt,
  );
  String get _negativeText => widget.item.negativePrompt.trim();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final positive = _positive ? _positiveText : '';
    final negative = _negative ? _negativeText : '';
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择导入内容',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  const Text('仅替换勾选的提示词，未勾选的部分保留原内容。'),
                  CheckboxListTile(
                    title: const Text('正向提示词'),
                    value: _positive,
                    onChanged: (v) => setState(() => _positive = v!),
                  ),
                  if (_positive &&
                      widget.item.prompt.trim().isNotEmpty &&
                      widget.item.tags.isNotEmpty)
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('原始提示词')),
                        ButtonSegment(value: true, label: Text('按标签选择')),
                      ],
                      selected: {_useTags},
                      onSelectionChanged: (v) =>
                          setState(() => _useTags = v.first),
                    ),
                  if (_positive && _useTags) ...[
                    Row(
                      children: [
                        Text(
                          '已选 ${_selected.length} / ${widget.item.tags.toSet().length} 个标签',
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setState(
                            () => _selected.addAll(widget.item.tags),
                          ),
                          child: const Text('全选'),
                        ),
                        TextButton(
                          onPressed: () => setState(_selected.clear),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                    for (final group in widget.item.groupedTags.entries) ...[
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        tristate: true,
                        title: Text(
                          '${group.key.label} (${group.value.length})',
                          style: TextStyle(
                            color: galleryTagColor(group.key, scheme),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        value: group.value.every(_selected.contains)
                            ? true
                            : group.value.any(_selected.contains)
                            ? null
                            : false,
                        onChanged: (_) => setState(() {
                          if (group.value.every(_selected.contains)) {
                            _selected.removeAll(group.value);
                          } else {
                            _selected.addAll(group.value);
                          }
                        }),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final tag in group.value)
                            FilterChip(
                              label: Text(tag.replaceAll('_', ' ')),
                              selected: _selected.contains(tag),
                              onSelected: (v) => setState(() {
                                v ? _selected.add(tag) : _selected.remove(tag);
                              }),
                            ),
                        ],
                      ),
                    ],
                  ],
                  if (widget.item.negativePrompt.trim().isNotEmpty)
                    CheckboxListTile(
                      title: const Text('负向提示词'),
                      value: _negative,
                      onChanged: (v) => setState(() => _negative = v!),
                    ),
                  const SizedBox(height: 16),
                  Text('导入预览', style: Theme.of(context).textTheme.titleMedium),
                  if (_positive)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: SelectableText(
                        positive.isEmpty ? '没有可导入的正向内容' : positive,
                      ),
                    ),
                  if (_negative)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: SelectableText(negative),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: positive.isEmpty && negative.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context,
                          GalleryPromptImport(
                            positive: positive.isEmpty ? null : positive,
                            negative: negative.isEmpty ? null : negative,
                          ),
                        ),
                  child: const Text('导入生图'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
