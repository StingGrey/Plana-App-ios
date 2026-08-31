import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/store/storage_stats.dart' show fmtBytes;
import '../../core/theme/app_theme.dart';
import '../generate/models.dart' show loraTypeLabel;
import '../generate/widgets/common.dart' show hintSnack;

/// 服务端单文件上限(app.py `_LORA_UPLOAD_MAX_BYTES`),先在本地挡一道,
/// 省得几百兆传上去才被拒。
const _kMaxUploadBytes = 2 * 1024 * 1024 * 1024;

/// 一次上传的表单结果。文件只带路径,真正的字节由 BackendClient 边读边发。
class LoraUploadDraft {
  const LoraUploadDraft({
    required this.path,
    required this.fileName,
    required this.size,
    required this.displayName,
    required this.triggerGroups,
    required this.type,
    required this.public,
  });

  final String path;
  final String fileName;
  final int size;
  final String displayName;

  /// 每条是一个「组/套装」(组内可含逗号),挂载时按组勾选。
  final List<String> triggerGroups;
  final String type;

  /// true = 进公共库人人可用;false = 私有,只有自己拉得到。
  final bool public;
}

/// 上传自己的 LoRA:选文件 → 填名称/触发词组/分类/可见性 → 把表单交回管理器。
///
/// 传输本身**不在这儿跑** —— 交给管理器页,面板关掉、去别的 tab 逛都不打断,
/// 免得几百兆的传输被一个模态框绑在原地。
Future<LoraUploadDraft?> showLoraUploadSheet(BuildContext context) {
  return showModalBottomSheet<LoraUploadDraft>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _LoraUploadSheet(),
  );
}

class _LoraUploadSheet extends StatefulWidget {
  const _LoraUploadSheet();

  @override
  State<_LoraUploadSheet> createState() => _LoraUploadSheetState();
}

class _LoraUploadSheetState extends State<_LoraUploadSheet> {
  final _name = TextEditingController();
  final _trigger = TextEditingController();
  final _groups = <String>[];
  String _type = 'character';
  bool _public = false;

  PlatformFile? _file;

  @override
  void dispose() {
    _name.dispose();
    _trigger.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    // FileType.any 而不是 custom:安卓的选择器按 MIME 过滤,.safetensors
    // 没有注册类型,给 custom 会把文件全灰掉挑不出来。后缀自己验。
    final res = await FilePicker.platform.pickFiles(withData: false);
    final f = res?.files.singleOrNull;
    if (f == null || !mounted) return;
    if (!f.name.toLowerCase().endsWith('.safetensors')) {
      hintSnack(context, '只支持 .safetensors 文件');
      return;
    }
    if (f.path == null) {
      hintSnack(context, '读不到这个文件,换个位置再试');
      return;
    }
    if (f.size > _kMaxUploadBytes) {
      hintSnack(context, '文件超过 ${_kMaxUploadBytes >> 30}GB 上限');
      return;
    }
    if (f.size < 1024) {
      // 服务端也拦这一档;本地先挡掉,顺带避免 0 字节把 contentLength 报错
      hintSnack(context, '不是有效的 safetensors 文件');
      return;
    }
    setState(() {
      _file = f;
      if (_name.text.trim().isEmpty) {
        _name.text = f.name.replaceAll(
          RegExp(r'\.safetensors$', caseSensitive: false),
          '',
        );
      }
    });
  }

  void _addGroup() {
    final g = _trigger.text.trim().replaceAll(RegExp(r'^[,，\s]+|[,，\s]+$'), '');
    _trigger.clear();
    if (g.isEmpty || _groups.contains(g)) {
      setState(() {});
      return;
    }
    setState(() => _groups.add(g));
  }

  void _submit() {
    final f = _file;
    if (f == null) return;
    // 输入框里没点「添加」的残留内容并进最后一组,免得白填
    final pending = _trigger.text.trim().replaceAll(
      RegExp(r'^[,，\s]+|[,，\s]+$'),
      '',
    );
    final groups = [
      ..._groups,
      if (pending.isNotEmpty && !_groups.contains(pending)) pending,
    ];
    Navigator.of(context).pop(
      LoraUploadDraft(
        path: f.path!,
        fileName: f.name,
        size: f.size,
        displayName: _name.text.trim().isEmpty
            ? f.name.replaceAll(
                RegExp(r'\.safetensors$', caseSensitive: false),
                '',
              )
            : _name.text.trim(),
        triggerGroups: groups,
        type: _type,
        public: _public,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final f = _file;
    return Padding(
      // 键盘弹起时把内容顶上去
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '上传 LoRA',
              style: context.texts.titleMedium!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            _FilePickTile(file: f, onTap: _pick),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.next,
              decoration: _dec(scheme, '名称(默认用文件名)'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _trigger,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _addGroup(),
                    decoration: _dec(scheme, '触发词组(组内可用逗号分隔)'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '添加这一组',
                  onPressed: _addGroup,
                  icon: const Icon(Icons.add, size: 20),
                ),
              ],
            ),
            if (_groups.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _groups.length; i++)
                    InputChip(
                      label: Text(
                        _groups[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      avatar: const Icon(Icons.key, size: 14),
                      visualDensity: VisualDensity.compact,
                      onDeleted: () => setState(() => _groups.removeAt(i)),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text('分类', style: context.texts.bodyMedium)),
                SegmentedButton<String>(
                  segments: [
                    for (final t in const ['character', 'style', 'concept'])
                      ButtonSegment(value: t, label: Text(loraTypeLabel(t))),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity(horizontal: -3, vertical: -3),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: Text('可见性', style: context.texts.bodyMedium)),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('私有'),
                      icon: Icon(Icons.lock_outline, size: 15),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('公开'),
                      icon: Icon(Icons.public, size: 15),
                    ),
                  ],
                  selected: {_public},
                  onSelectionChanged: (s) => setState(() => _public = s.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity(horizontal: -3, vertical: -3),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: f == null ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(23),
                ),
              ),
              child: const Text('开始上传'),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _dec(ColorScheme scheme, String hint) => InputDecoration(
    isDense: true,
    filled: true,
    fillColor: scheme.surfaceContainerHigh,
    hintText: hint,
    hintStyle: TextStyle(color: scheme.outline),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
  );
}

/// 选文件行:没选时是虚线框的入口,选了就显示文件名 + 体积。
class _FilePickTile extends StatelessWidget {
  const _FilePickTile({required this.file, required this.onTap});

  final PlatformFile? file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final f = file;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Icon(
                f == null ? Icons.upload_file : Icons.description_outlined,
                size: 20,
                color: f == null ? scheme.onSurfaceVariant : scheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f?.name ?? '选择 .safetensors 文件',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodyMedium!.copyWith(
                        color: f == null ? scheme.onSurfaceVariant : null,
                      ),
                    ),
                    if (f != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        fmtBytes(f.size),
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (f != null)
                Text(
                  '重选',
                  style: context.texts.labelMedium!.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
