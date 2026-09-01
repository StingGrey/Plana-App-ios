import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import '../generate/generate_state.dart';
import '../generate/models.dart' show GenerateState;
import '../shell/shell_state.dart';

import '../generate/widgets/common.dart' show hintSnack, sharedAxisRoute;
import '../import/import_panel.dart';
import '../inspiration/prompt_library_save.dart';
import 'models.dart';

/// Detail view for a generated result, including its exact generation snapshot.
class ResultDetailPage extends ConsumerStatefulWidget {
  const ResultDetailPage({super.key, required this.result});

  final ResultImage result;

  @override
  ConsumerState<ResultDetailPage> createState() => _ResultDetailPageState();
}

class _ResultDetailPageState extends ConsumerState<ResultDetailPage> {
  Uint8List? _bytes;
  GenerateState? _input;
  bool _loading = true;

  ResultImage get result => widget.result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(appStoresProvider).gallery;
    final bytes = result.bytes ?? await store.readImage(result.id);
    final input =
        result.input ??
        (result.hasInput ? await store.readInput(result.id) : null);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _input = input;
      _loading = false;
    });
  }

  Future<void> _copy(String label, String text) async {
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) hintSnack(context, '已复制$label', icon: Icons.copy);
  }

  void _loadToWorkspace() {
    final input = _input;
    if (input == null) {
      hintSnack(context, '这张图没有参数快照', icon: Icons.info_outline);
      return;
    }
    ref.read(generateProvider.notifier).loadSnapshot(input);
    Navigator.of(context).pop();
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
  }

  Future<void> _openImport() async {
    final bytes = _bytes;
    if (bytes == null) {
      hintSnack(context, '图片尚未就绪', icon: Icons.hourglass_empty);
      return;
    }
    await Navigator.of(context).push(
      sharedAxisRoute(
        ImportImagePanel(
          bytes: bytes,
          fileName: 'plana_${result.seed}.png',
          displayName: 'plana_${result.seed}',
        ),
      ),
    );
  }

  Future<void> _saveToLibrary() async {
    final input = _input;
    if (input == null || input.prompt.trim().isEmpty) {
      hintSnack(context, '这张图没有可保存的提示词', icon: Icons.info_outline);
      return;
    }
    final saved = await savePromptToTagLibrary(
      context,
      ref,
      prompt: input.prompt,
      negative: input.negativePrompt,
      suggestedName: 'Seed ${result.seed}',
    );
    if (saved && mounted) {
      hintSnack(context, '已保存到词库', icon: Icons.bookmark_added_outlined);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final input = _input;
    return Scaffold(
      appBar: AppBar(
        title: const Text('图片详情'),
        actions: [
          IconButton(
            tooltip: '导入参数 / 用作参考',
            icon: const Icon(Icons.input),
            onPressed: _loading ? null : _openImport,
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              if (value == 'library') _saveToLibrary();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'library', child: Text('保存正负提示词到词库')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: FilledButton.icon(
            onPressed: input == null ? null : _loadToWorkspace,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('载入创作页'),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final tablet = constraints.maxWidth >= 700;
                if (!tablet) {
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                    children: [
                      _image(scheme),
                      const SizedBox(height: 15),
                      ..._parameterSections(input, scheme),
                    ],
                  );
                }
                return _tabletBody(input, scheme, constraints);
              },
            ),
    );
  }

  List<Widget> _parameterSections(GenerateState? input, ColorScheme scheme) => [
    _overview(input, scheme),
    if (input != null && input.prompt.isNotEmpty) ...[
      const SizedBox(height: 18),
      _textSection('正向提示词', input.prompt, scheme),
    ],
    if (input != null && input.negativePrompt.isNotEmpty) ...[
      const SizedBox(height: 14),
      _textSection('负向提示词', input.negativePrompt, scheme, danger: true),
    ],
    if (input != null && input.characters.isNotEmpty) ...[
      const SizedBox(height: 18),
      Text(
        '角色提示词',
        style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      for (var i = 0; i < input.characters.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _textSection(
            '角色 ${i + 1}${input.characters[i].enabled ? '' : ' · 已停用'}',
            input.characters[i].positive,
            scheme,
            compact: true,
          ),
        ),
    ],
    if (input != null && input.negativePrompt.isNotEmpty) ...[
      const SizedBox(height: 4),
      Text(
        '角色负向提示词包含在参数快照中，可通过导入面板逐项查看。',
        style: context.texts.labelSmall!.copyWith(color: scheme.outline),
      ),
    ],
    if (input != null && input.loras.isNotEmpty) ...[
      const SizedBox(height: 18),
      _resourceSection('LoRA (${input.loras.length})', [
        for (final lora in input.loras)
          '${lora.displayName} · ${lora.weight.toStringAsFixed(2)}',
      ], scheme),
    ],
    if (input != null && input.vibes.isNotEmpty) ...[
      const SizedBox(height: 14),
      _resourceSection('Vibe Transfer (${input.vibes.length})', [
        for (final vibe in input.vibes)
          '${vibe.name.isEmpty ? 'Vibe' : vibe.name} · 强度 ${vibe.strength.toStringAsFixed(2)}',
      ], scheme),
    ],
    if (input != null && input.charRefs.isNotEmpty) ...[
      const SizedBox(height: 14),
      _resourceSection('角色参考 (${input.charRefs.length})', [
        for (final reference in input.charRefs)
          '${reference.name.isEmpty ? '参考图' : reference.name} · ${reference.mode.label}',
      ], scheme),
    ],
  ];

  Widget _tabletBody(
    GenerateState? input,
    ColorScheme scheme,
    BoxConstraints constraints,
  ) {
    final availableHeight = constraints.hasBoundedHeight
        ? math.max(0.0, constraints.maxHeight - 32)
        : MediaQuery.sizeOf(context).height;
    // Keep the picture visually subordinate to the parameter pane on a
    // landscape tablet instead of letting a portrait image consume the whole
    // vertical viewport.
    final maxImageHeight = math.min(
      availableHeight,
      MediaQuery.sizeOf(context).height * .82,
    );
    return Row(
      key: const ValueKey('tablet-result-detail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 560,
                  maxHeight: maxImageHeight,
                ),
                child: _image(scheme),
              ),
            ),
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: scheme.outlineVariant),
        Expanded(
          flex: 6,
          child: SingleChildScrollView(
            key: const ValueKey('tablet-result-detail-parameters'),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '参数与提示词',
                  style: context.texts.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                ..._parameterSections(input, scheme),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _image(ColorScheme scheme) => AspectRatio(
    aspectRatio: result.width > 0 && result.height > 0 ? result.aspect : 1,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: _bytes == null
          ? Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 45,
                color: scheme.outline,
              ),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.memory(_bytes!, fit: BoxFit.contain),
            ),
    ),
  );

  Widget _overview(GenerateState? input, ColorScheme scheme) {
    final p = input?.params;
    final values = <(String, String)>[
      ('尺寸', '${result.width} × ${result.height}'),
      ('Seed', '${result.seed}'),
      if (p != null) ('模型', p.model),
      if (p != null) ('步数', '${p.activeSteps}'),
      if (p != null) ('CFG', p.cfg.toStringAsFixed(2)),
      if (p != null) ('采样器', p.sampler),
      if (p != null) ('噪声调度', p.noiseSchedule),
      if (result.badge.label != null) ('处理', result.badge.label!),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, value) in values) _Info(label: label, value: value),
      ],
    );
  }

  Widget _resourceSection(
    String title,
    List<String> values,
    ColorScheme scheme,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: context.texts.titleSmall!.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 7),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final value in values)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(value, style: context.texts.bodySmall),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _textSection(
    String title,
    String text,
    ColorScheme scheme, {
    bool danger = false,
    bool compact = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            title,
            style: context.texts.labelLarge!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '复制',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () => _copy(title, text),
          ),
        ],
      ),
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 10 : 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          text.isEmpty ? '(空)' : text,
          style: context.texts.bodySmall!.copyWith(
            height: 1.55,
            color: danger ? scheme.error : scheme.onSurface,
          ),
        ),
      ),
    ],
  );
}

class _Info extends StatelessWidget {
  const _Info({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 88, maxWidth: 220),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: context.scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.texts.labelSmall!.copyWith(
            color: context.scheme.outline,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.texts.bodySmall,
        ),
      ],
    ),
  );
}
