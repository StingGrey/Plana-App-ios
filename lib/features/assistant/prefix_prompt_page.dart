/// 前置提示词:用户自己写给 AI 助手的一段话,每轮都排在规则最前面发出去
/// (见 `withPrefix`)。
///
/// 和规则预设分开放:预设是一整套「怎么写提示词」,换预设是换整套;前置词是
/// 用户自己的几句偏好,换哪套预设都跟着走。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../generate/widgets/common.dart' show confirmDialog;
import 'assistant_settings.dart';

class PrefixPromptPage extends ConsumerStatefulWidget {
  const PrefixPromptPage({super.key});

  @override
  ConsumerState<PrefixPromptPage> createState() => _PrefixPromptPageState();
}

class _PrefixPromptPageState extends ConsumerState<PrefixPromptPage> {
  late final _ctl = TextEditingController(
    text: ref.read(assistantSettingsProvider).value?.prefixPrompt ?? '',
  );
  var _dirty = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _ctl.text.trim();
    await ref
        .read(assistantSettingsProvider.notifier)
        .patch((o) => o.copyWith(prefixPrompt: text));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _confirmLeave() async {
    final ok = await confirmDialog(
      context,
      title: '放弃修改?',
      message: '还没保存的改动会丢掉。',
      confirmLabel: '放弃',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('前置提示词'),
          actions: [
            IconButton(
              tooltip: '保存',
              onPressed: _save,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '写给 AI 助手的话,每轮都放在它的规则最前面。'
                  '只影响写提示词的 AI,不会写进出图的提示词。',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _ctl,
                  expands: true,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  onChanged: (_) {
                    if (!_dirty) setState(() => _dirty = true);
                  },
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: '例:回复一律用中文,先简短说说构思再给提示词',
                    contentPadding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
