import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/gallery_save.dart';
import '../../core/util/image_ops.dart';
import '../../core/util/image_pick.dart';
import '../../core/util/image_scramble.dart';
import '../generate/widgets/common.dart' show hintSnack;

enum _ResultKind { scrambled, restored }

/// PNGPKG 兼容的图片混淆 / 解混淆独立页面。
class ImageScramblePage extends StatefulWidget {
  const ImageScramblePage({super.key});

  @override
  State<ImageScramblePage> createState() => _ImageScramblePageState();
}

class _ImageScramblePageState extends State<ImageScramblePage> {
  final _offsetController = TextEditingController();
  PickedImage? _picked;
  Uint8List? _result;
  (int, int)? _size;
  _ResultKind? _resultKind;
  int _percent = 62;
  int _offset = 0;
  bool _goldenOffset = true;
  bool _processing = false;
  bool _saving = false;

  int get _pixelCount => switch (_size) {
    (final w, final h) => w * h,
    null => 0,
  };

  Uint8List? get _displayBytes => _result ?? _picked?.bytes;

  @override
  void dispose() {
    _offsetController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await pickImageFile(context);
    if (picked == null || !mounted) return;
    try {
      final size = await decodeImageSize(picked.bytes);
      if (!mounted) return;
      setState(() {
        _picked = picked;
        _result = null;
        _resultKind = null;
        _size = size;
        _setPercent(62, notify: false);
      });
    } catch (_) {
      if (mounted) {
        hintSnack(context, '无法读取这张图片', icon: Icons.broken_image_outlined);
      }
    }
  }

  void _setPercent(int percent, {bool notify = true}) {
    final normalized = percent.clamp(0, 100);
    void apply() {
      _percent = normalized;
      _offset = pngPkgOffsetForPercent(_pixelCount, normalized);
      _goldenOffset = normalized == 62;
      _offsetController.text = '$_offset';
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  void _commitExactOffset() {
    if (_pixelCount <= 0) return;
    final parsed = int.tryParse(_offsetController.text);
    final exact = (parsed ?? _offset).clamp(0, _pixelCount);
    final golden = pngPkgOffsetForPercent(_pixelCount, 62);
    setState(() {
      _offset = exact;
      _percent = ((exact / _pixelCount) * 100).round().clamp(0, 100);
      _goldenOffset = exact == golden;
      _offsetController.text = '$exact';
    });
  }

  Future<void> _transform({required bool decrypt}) async {
    final source = _displayBytes;
    if (source == null || _processing) return;
    _commitExactOffset();
    final offset = _offset;
    setState(() => _processing = true);
    try {
      final output = await transformPngPkgImage(
        source,
        offset: offset,
        decrypt: decrypt,
      );
      if (!mounted) return;
      setState(() {
        _result = output;
        _resultKind = decrypt ? _ResultKind.restored : _ResultKind.scrambled;
      });
      hintSnack(
        context,
        decrypt ? '解混淆完成' : '混淆完成',
        icon: decrypt ? Icons.lock_open_outlined : Icons.shuffle_rounded,
      );
    } catch (_) {
      if (mounted) {
        hintSnack(context, '图片处理失败', icon: Icons.error_outline);
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _resetResult() {
    if (_result == null) return;
    setState(() {
      _result = null;
      _resultKind = null;
    });
  }

  Future<void> _saveResult() async {
    final result = _result;
    final picked = _picked;
    final kind = _resultKind;
    if (result == null || picked == null || kind == null || _saving) return;
    setState(() => _saving = true);
    try {
      final allowed = await Gal.hasAccess() || await Gal.requestAccess();
      if (!allowed) {
        if (mounted) {
          hintSnack(context, '未获相册权限', icon: Icons.error_outline);
        }
        return;
      }
      final suffix = kind == _ResultKind.scrambled ? '_scrambled' : '_restored';
      await saveImageBytesToGallery(
        result,
        name: '${picked.baseName}$suffix',
        extension: 'png',
      );
      if (mounted) {
        hintSnack(context, '已保存到相册', icon: Icons.check_circle_outline);
      }
    } catch (_) {
      if (mounted) {
        hintSnack(context, '保存失败', icon: Icons.error_outline);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    return Scaffold(
      appBar: AppBar(
        title: const Text('图片混淆与解混淆'),
        actions: [
          if (_result != null)
            IconButton(
              onPressed: _processing ? null : _resetResult,
              icon: const Icon(Icons.restart_alt),
              tooltip: '恢复原图',
            ),
          if (picked != null)
            IconButton(
              onPressed: _processing ? null : _pickImage,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              tooltip: '更换图片',
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: picked == null ? _emptyView() : _contentView(picked),
      ),
    );
  }

  Widget _emptyView() {
    final scheme = context.scheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shuffle_rounded, size: 52, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              '使用 Gilbert 曲线无损置换图片像素',
              textAlign: TextAlign.center,
              style: context.texts.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '兼容 PNGPKG：解混淆时需使用与混淆时完全相同的偏移量',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('选择图片'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contentView(PickedImage picked) {
    final scheme = context.scheme;
    final size = _size!;
    final previewHeight = math.min(
      MediaQuery.sizeOf(context).height * .46,
      430.0,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
      children: [
        Container(
          height: previewHeight,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Image.memory(
                  _displayBytes!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    size: 44,
                    color: scheme.outline,
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: .88),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      child: Text(
                        '${picked.name} · ${size.$1}×${size.$2}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.labelSmall,
                      ),
                    ),
                  ),
                ),
              ),
              if (_processing)
                ColoredBox(
                  color: scheme.scrim.withValues(alpha: .22),
                  child: const Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '像素偏移',
                    style: context.texts.titleSmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _goldenOffset ? '默认 · 黄金分割' : '自定义 · $_percent%',
                    style: context.texts.bodySmall!.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
              Slider(
                value: _percent.toDouble(),
                min: 0,
                max: 100,
                divisions: 100,
                label: '$_percent%',
                onChanged: _processing
                    ? null
                    : (value) => _setPercent(value.round()),
              ),
              TextField(
                controller: _offsetController,
                enabled: !_processing,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _commitExactOffset(),
                decoration: InputDecoration(
                  labelText: '精确偏移量',
                  helperText: '范围 0–$_pixelCount；与 PNGPKG 互通时可直接填写像素值',
                  suffixIcon: IconButton(
                    onPressed: _processing ? null : _commitExactOffset,
                    icon: const Icon(Icons.check),
                    tooltip: '应用偏移量',
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _processing
                          ? null
                          : () => _transform(decrypt: false),
                      icon: const Icon(Icons.shuffle_rounded, size: 19),
                      label: const Text('混淆图片'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _processing
                          ? null
                          : () => _transform(decrypt: true),
                      icon: const Icon(Icons.lock_open_outlined, size: 19),
                      label: const Text('解混淆'),
                    ),
                  ),
                ],
              ),
              if (_result != null) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _saving || _processing ? null : _saveResult,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_alt, size: 19),
                  label: const Text('保存结果到相册'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
