/// 前置提示词:用户自己写给 AI 助手的一段话,每轮都排在系统提示最前面发出去
/// (见 `composeSystemPrompt`)。
///
/// 和规则预设分开放:预设是一整套「怎么写提示词」,换预设是换整套;前置词是
/// 用户自己的几句偏好,换哪套预设都跟着走。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
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
      title: context.l10n.discardChangesQ,
      message: context.l10n.unsavedLost2,
      confirmLabel: context.l10n.discardAction,
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
          title: Text(context.l10n.prefixPrompt),
          actions: [
            IconButton(
              tooltip: context.l10n.save,
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
                  context.l10n.prefixPromptNote,
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
                  maxLength: AssistantSettings.prefixPromptMax,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  onChanged: (_) {
                    if (!_dirty) setState(() => _dirty = true);
                  },
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: context.l10n.prefixPromptHint,
                    contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
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
