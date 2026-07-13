import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/anlas_provider.dart';
import '../../core/theme/app_theme.dart';
import '../generate/generate_state.dart';
import '../generate/nai_request.dart' show naiModelId;
import '../generate/vibe_encoder.dart';
import '../generate/widgets/common.dart'
    show ParamSlider, confirmDialog, hintSnack;
import 'naiv4vibe_codec.dart' show jsNum, kEncodingKeyLabel, kModelToEncodingKey;
import 'vibe_library.dart';

/// 预编码可选模型(与生成页模型集合一致)。
const _precodeModels = [
  ('nai-diffusion-4-5-full', 'NAI 4.5 Full'),
  ('nai-diffusion-4-5-curated', 'NAI 4.5 Curated'),
  ('nai-diffusion-4-full', 'NAI 4.0 Full'),
  ('nai-diffusion-4-curated-preview', 'NAI 4.0 Curated'),
];

/// 库条目详情:大图 + 名称/默认参数编辑 + 编码清单(显式化「哪些模型×IE
/// 已有编码」)+ 预编码(明示 2 Anlas)+ 导出/删除/添加到生成。
/// pop(true) = 已添加到生成(由库页收尾:snack + 返回生成页)。
class VibeDetailSheet extends ConsumerStatefulWidget {
  const VibeDetailSheet({super.key, required this.entryId});

  final String entryId;

  @override
  ConsumerState<VibeDetailSheet> createState() => _VibeDetailSheetState();
}

class _VibeDetailSheetState extends ConsumerState<VibeDetailSheet> {
  double? _strength; // 本地滑条值(null = 未初始化,取 entry 默认)
  double? _ie;
  Timer? _saveTimer;
  Future<Uint8List?>? _imageFuture;
  Future<List<({String modelKey, double? ie})>>? _encFuture;

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  VibeEntry? get _entry {
    final list = ref.watch(vibeLibraryProvider).value;
    if (list == null) return null;
    for (final e in list) {
      if (e.id == widget.entryId) return e;
    }
    return null;
  }

  void _scheduleSave(VibeEntry e) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), () {
      ref.read(vibeLibraryProvider.notifier).updateMeta(
            e.id,
            defaultStrength: _strength,
            defaultInfoExtracted: _ie,
          );
    });
  }

  Future<void> _rename(VibeEntry e) async {
    final ctl = TextEditingController(text: e.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(isDense: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(vibeLibraryProvider.notifier).updateMeta(e.id, name: name);
    }
  }

  Future<void> _export(VibeEntry e) async {
    try {
      final text = await ref.read(vibeLibraryProvider.notifier).exportText(e);
      final safe = e.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final path = await FilePicker.platform.saveFile(
        fileName: '$safe.naiv4vibe',
        bytes: utf8.encode(text),
      );
      if (path != null && mounted) {
        hintSnack(context, '已导出 $safe.naiv4vibe',
            icon: Icons.check_circle_outline);
      }
    } catch (err) {
      if (mounted) hintSnack(context, '导出失败:$err', icon: Icons.error_outline);
    }
  }

  Future<void> _delete(VibeEntry e) async {
    final ok = await confirmDialog(
      context,
      title: '删除 Vibe',
      message: '「${e.name}」将从库中删除(文件与缩略图一并移除),不可恢复。',
      confirmLabel: '删除',
    );
    if (!ok || !mounted) return;
    await ref.read(vibeLibraryProvider.notifier).delete(e.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addToGenerate(VibeEntry e) async {
    final gen = ref.read(generateProvider);
    final dup = gen.vibes.any(
      (v) =>
          (e.id == v.sourceId) ||
          (v.imageHash != null && v.imageHash == e.imageHash),
    );
    if (dup) {
      hintSnack(context, '已在生成面板中', icon: Icons.info_outline);
      return;
    }
    final data =
        await ref.read(vibeLibraryProvider.notifier).loadForGenerate(e);
    if (!mounted) return;
    if (data == null) {
      hintSnack(context, '无法读取该 Vibe 文件', icon: Icons.error_outline);
      return;
    }
    final id = ref.read(generateProvider.notifier).addVibe(
          image: data.image,
          name: e.name,
          imageHash: data.imageHash,
          strength: _strength ?? e.defaultStrength ?? 0.6,
          infoExtracted: data.image != null
              ? (_ie ?? e.defaultInfoExtracted ?? 1.0)
              : data.fixedInfoExtracted,
          encodedByModel: data.encodedByModel,
          sourceId: e.id,
        );
    if (id.isEmpty) {
      hintSnack(context, '该 Vibe 没有可用的图片或编码', icon: Icons.error_outline);
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _openPrecode(VibeEntry e) async {
    final img = await _imageFuture;
    if (!mounted) return;
    if (img == null) {
      hintSnack(context, '该 Vibe 无原图,无法编码新参数', icon: Icons.info_outline);
      return;
    }
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PrecodeSheet(
        entry: e,
        image: img,
        initialIe: _ie ?? e.defaultInfoExtracted ?? 1.0,
      ),
    );
    if (done == true && mounted) {
      // 刷新编码清单
      setState(() {
        _encFuture = ref.read(vibeLibraryProvider.notifier).encodingList(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final e = _entry;
    if (e == null) {
      // 条目被删/库未就绪:空壳(删除路径已主动 pop)
      return const SizedBox(height: 120);
    }
    _strength ??= e.defaultStrength ?? 0.6;
    _ie ??= e.defaultInfoExtracted ?? 1.0;
    _imageFuture ??= ref.read(vibeLibraryProvider.notifier).loadImageBytes(e);
    _encFuture ??= ref.read(vibeLibraryProvider.notifier).encodingList(e);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _preview(scheme),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    e.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.titleMedium!
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '重命名',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _rename(e),
                  icon: Icon(Icons.edit_outlined,
                      size: 19, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            Text(
              [
                _fmtTime(e.createdAt),
                if (e.sizeBytes > 0)
                  '${(e.sizeBytes / 1024 / 1024).toStringAsFixed(2)} MB',
                if (!e.hasImage) '仅编码(无原图)',
              ].join(' · '),
              style:
                  context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
            const SizedBox(height: 14),
            ParamSlider(
              label: 'Strength 默认强度',
              value: _strength!,
              divisions: 100,
              onChanged: (v) {
                setState(() => _strength = v);
                _scheduleSave(e);
              },
            ),
            const SizedBox(height: 4),
            if (e.hasImage)
              ParamSlider(
                label: 'Info Extracted 默认信息提取',
                value: _ie!,
                divisions: 100,
                onChanged: (v) {
                  setState(() => _ie = v);
                  _scheduleSave(e);
                },
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Info Extracted 随编码固定,无原图不可调整。',
                  style: context.texts.labelSmall!
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 12),
            _encodings(e, scheme),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _addToGenerate(e),
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
              label: const Text('添加到生成'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _export(e),
                    icon: const Icon(Icons.ios_share, size: 17),
                    label: const Text('导出'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _delete(e),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 17),
                    label: const Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(ColorScheme scheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        color: scheme.surfaceContainerHigh,
        constraints: const BoxConstraints(maxHeight: 240),
        width: double.infinity,
        child: FutureBuilder<Uint8List?>(
          future: _imageFuture,
          builder: (context, snap) {
            final bytes = snap.data;
            if (bytes == null) {
              return SizedBox(
                height: 130,
                child: Center(
                  child: snap.connectionState == ConnectionState.waiting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.data_object,
                          size: 34, color: scheme.outline),
                ),
              );
            }
            return Image.memory(bytes, fit: BoxFit.contain);
          },
        ),
      ),
    );
  }

  Widget _encodings(VibeEntry e, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '已有编码',
              style: context.texts.labelMedium!
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            if (e.hasImage)
              TextButton.icon(
                onPressed: () => _openPrecode(e),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.bolt_outlined, size: 16),
                label: const Text('预编码'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        FutureBuilder(
          future: _encFuture,
          builder: (context, snap) {
            final list = snap.data ?? const [];
            if (list.isEmpty) {
              return Text(
                snap.connectionState == ConnectionState.waiting
                    ? '加载中…'
                    : '暂无编码,生成时将现场编码(2 Anlas/次,自动缓存)。',
                style: context.texts.labelSmall!
                    .copyWith(color: scheme.outline),
              );
            }
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final it in list)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer.withValues(alpha: .6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${kEncodingKeyLabel[it.modelKey] ?? it.modelKey}'
                      ' · IE ${it.ie == null ? '?' : jsNum(it.ie!)}',
                      style: context.texts.labelSmall!.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  static String _fmtTime(int ms) {
    if (ms <= 0) return '—';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 预编码二级 sheet:选模型 + IE,明示 Anlas 成本;命中缓存则免扣。
class _PrecodeSheet extends ConsumerStatefulWidget {
  const _PrecodeSheet({
    required this.entry,
    required this.image,
    required this.initialIe,
  });

  final VibeEntry entry;
  final Uint8List image;
  final double initialIe;

  @override
  ConsumerState<_PrecodeSheet> createState() => _PrecodeSheetState();
}

class _PrecodeSheetState extends ConsumerState<_PrecodeSheet> {
  // 默认选当前生成页的模型(编码通常是为它准备的)
  late String _model = () {
    final cur = naiModelId(ref.read(generateProvider).params.model);
    return _precodeModels.any((m) => m.$1 == cur)
        ? cur
        : _precodeModels.first.$1;
  }();
  late double _ie = widget.initialIe;
  bool _busy = false;

  Future<void> _run() async {
    final hash = widget.entry.imageHash;
    if (hash == null) return;
    setState(() => _busy = true);
    final encoder = ref.read(vibeEncoderProvider);
    try {
      final hit = await encoder.cached(
        imageHash: hash,
        model: _model,
        infoExtracted: _ie,
      );
      if (hit != null) {
        if (mounted) {
          hintSnack(context, '该参数已有编码,无需重复编码',
              icon: Icons.check_circle_outline);
          Navigator.pop(context, true);
        }
        return;
      }
      await encoder.encode(
        image: widget.image,
        imageHash: hash,
        model: _model,
        infoExtracted: _ie,
      );
      ref.read(anlasProvider.notifier).refresh(); // 编码扣了 2 Anlas
      if (mounted) {
        hintSnack(context, '编码完成(消耗 2 Anlas,已缓存)',
            icon: Icons.check_circle_outline);
        Navigator.pop(context, true);
      }
    } catch (err) {
      if (mounted) {
        setState(() => _busy = false);
        hintSnack(context, '编码失败:$err', icon: Icons.error_outline);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final modelKey = kModelToEncodingKey[_model] ?? _model;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 14),
          Text(
            '预编码',
            style: context.texts.titleMedium!
                .copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '提前为指定模型和 IE 生成编码并缓存;之后用该参数生成不再扣编码费。'
            '新参数编码消耗 2 Anlas,已缓存的参数免费。',
            style: context.texts.labelSmall!.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          InputDecorator(
            decoration: const InputDecoration(
              isDense: true,
              labelText: '模型',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _model,
                isExpanded: true,
                isDense: true,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _model = v ?? _model),
                items: [
                  for (final (id, label) in _precodeModels)
                    DropdownMenuItem(
                      value: id,
                      child: Text('$label(${kEncodingKeyLabel[kModelToEncodingKey[id]] ?? id})'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          ParamSlider(
            label: 'Info Extracted',
            value: _ie,
            divisions: 100,
            onChanged: _busy ? (_) {} : (v) => setState(() => _ie = v),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: _busy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt, size: 18),
              label: Text(
                _busy
                    ? '编码中…'
                    : '编码 ${kEncodingKeyLabel[modelKey] ?? modelKey} · IE ${jsNum(_ie)}',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
