import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tag_library.dart';
import 'tag_models.dart';

/// Saves a prompt snapshot as a reusable local tag-library entry.
///
/// The dialog deliberately asks for a name and category instead of silently
/// putting every imported prompt in one bucket. This is the mobile equivalent
/// of the desktop "send to prompt library" action.
Future<bool> savePromptToTagLibrary(
  BuildContext context,
  WidgetRef ref, {
  required String prompt,
  String negative = '',
  String suggestedName = '',
  TagCategory initialCategory = TagCategory.other,
}) async {
  if (prompt.trim().isEmpty) return false;
  final nameController = TextEditingController(
    text: suggestedName.trim().isEmpty ? '导入提示词' : suggestedName.trim(),
  );
  var category = initialCategory;
  final result = await showDialog<({String name, TagCategory category})>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setLocalState) => AlertDialog(
        title: const Text('保存到词库'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例如：冬日街景',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<TagCategory>(
              initialValue: category,
              decoration: const InputDecoration(
                labelText: '分类',
                isDense: true,
              ),
              items: [
                for (final definition in kTagCategoryDefs)
                  DropdownMenuItem(
                    value: definition.key,
                    child: Text(definition.label),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setLocalState(() => category = value);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(dialogContext, (name: name, category: category));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  nameController.dispose();
  if (result == null || !context.mounted) return false;

  final library = ref.read(tagLibraryProvider.notifier);
  // Ensure an existing library is hydrated before upsert; otherwise opening
  // this action directly from a gallery detail could overwrite older entries
  // while the async store is still loading.
  try {
    await ref.read(tagLibraryProvider.future);
    final entry = TagEntry(
      id: TagLibrary.newId(result.category),
      category: result.category,
      name: result.name,
      positive: prompt.trim(),
      negative: negative.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await library.upsert(entry);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('词库保存失败：$error')),
      );
    }
    return false;
  }
  return true;
}
