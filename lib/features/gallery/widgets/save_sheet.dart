import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../../../core/store/storage_stats.dart' show fmtBytes;
import '../../../core/theme/app_theme.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../save_pipeline.dart';
import '../save_settings.dart';

/// 保存设置面板(长按图库「保存」进入,对齐 web SaveModal):
/// 格式 PNG/JPG + 压缩质量、元数据 原始/清除/自定义、实时预估大小;
/// 「单次保存」按面板当前选项存这一张,「设为默认」持久化为点按保存的默认行为。
Future<void> showSaveSheet(
  BuildContext context, {
  required Uint8List bytes,
  required int seed,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SaveSheet(bytes: bytes, seed: seed),
  );
}

class _SaveSheet extends ConsumerStatefulWidget {
  const _SaveSheet({required this.bytes, required this.seed});

  final Uint8List bytes;
  final int seed;

  @override
  ConsumerState<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends ConsumerState<_SaveSheet> {
  late SaveSettings _s;
  final _customCtl = TextEditingController();
  Timer? _debounce;
  int _seq = 0;
  int? _size;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _s = ref.read(saveSettingsProvider).value ?? const SaveSettings();
    _customCtl.text = _s.customPrompt;
    _estimate();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _customCtl.dispose();
    super.dispose();
  }

  SaveSettings get _current => _s.copyWith(customPrompt: _customCtl.text);

  void _set(SaveSettings next) {
    setState(() => _s = next);
    _estimate();
  }

  /// 预估 = 真实处理一遍取长度(节流,JPG 拖质量时不狂算)。
  void _estimate() {
    final seq = ++_seq;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final out = await processForSave(widget.bytes, _current);
        if (mounted && seq == _seq) setState(() => _size = out.length);
      } catch (_) {
        if (mounted && seq == _seq) setState(() => _size = null);
      }
    });
    setState(() => _size = null);
  }

  Future<void> _saveOnce() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final ok = await Gal.hasAccess() || await Gal.requestAccess();
      if (!ok) {
        if (mounted) hintSnack(context, '未获相册权限', icon: Icons.error_outline);
        return;
      }
      final out = await processForSave(widget.bytes, _current);
      await Gal.putImageBytes(out, name: 'plana_${widget.seed}');
      if (!mounted) return;
      hintSnack(
        context,
        '已保存到相册 · ${fmtBytes(out.length)}',
        icon: Icons.check_circle_outline,
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) hintSnack(context, '保存失败: $e', icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _applyDefault() async {
    final next = _current;
    await ref.read(saveSettingsProvider.notifier).patch((_) => next);
    if (!mounted) return;
    hintSnack(context, '已设为默认保存方式', icon: Icons.check_circle_outline);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final ext = _s.format == SaveFormat.jpg ? 'jpg' : 'png';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          12 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      widget.bytes,
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                      cacheWidth: 128,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'plana_${widget.seed}.$ext',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodyMedium!.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '预估大小 ${_size == null ? '计算中…' : fmtBytes(_size!)}',
                          style: context.texts.bodySmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SegmentedButton<SaveFormat>(
                segments: const [
                  ButtonSegment(
                    value: SaveFormat.png,
                    label: Text('PNG 无损'),
                  ),
                  ButtonSegment(
                    value: SaveFormat.jpg,
                    label: Text('JPG 有损'),
                  ),
                ],
                selected: {_s.format},
                onSelectionChanged: (v) => _set(_s.copyWith(format: v.first)),
                showSelectedIcon: false,
              ),
              if (_s.format == SaveFormat.jpg) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('压缩质量', style: context.texts.bodySmall),
                    const Spacer(),
                    Text(
                      '${(_s.quality * 100).round()}',
                      style: mono(context, size: 13),
                    ),
                  ],
                ),
                Slider(
                  value: (_s.quality * 100).roundToDouble().clamp(10, 100),
                  min: 10,
                  max: 100,
                  divisions: 90,
                  onChanged: (v) => _set(_s.copyWith(quality: v / 100)),
                ),
                Text(
                  'JPG 不保留元数据',
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 6),
                RadioGroup<SaveMeta>(
                  groupValue: _s.meta,
                  onChanged: (v) {
                    if (v != null) _set(_s.copyWith(meta: v));
                  },
                  child: Column(
                    children: [
                      for (final m in SaveMeta.values)
                        RadioListTile<SaveMeta>(
                          value: m,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            switch (m) {
                              SaveMeta.original => '保留原始元数据',
                              SaveMeta.clean => '清除元数据',
                              SaveMeta.custom => '自定义提示词',
                            },
                            style: context.texts.bodyMedium,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_s.meta == SaveMeta.custom)
                  TextField(
                    controller: _customCtl,
                    minLines: 2,
                    maxLines: 4,
                    style: mono(context, size: 12, weight: FontWeight.w400),
                    onChanged: (_) => _estimate(),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: scheme.surfaceContainerHigh,
                      hintText: '写入图片的提示词(其余参数清除)…',
                      hintStyle:
                          TextStyle(color: scheme.outline, fontSize: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _saving ? null : _saveOnce,
                      icon: _saving
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_alt, size: 18),
                      label: const Text('单次保存'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _applyDefault,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('设为默认'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
