/// 更新说明的排版。GitHub release 正文是 Markdown,原样贴出来满屏 `##` 和 `**`。
///
/// 只认发版时实际会写的几样:`#` 标题、单独成行的粗体(当小标题)、`-` / `1.` 列表、
/// 行内粗体与代码;链接只留文字。其余原样当正文 —— 认不出的多几个符号而已,
/// 不值得为它引一整个 Markdown 包。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

enum NoteKind { heading, sub, item, para }

typedef NoteBlock = ({NoteKind kind, String text, String marker, int indent});

final _heading = RegExp(r'^(#{1,6})\s+(.*?)[\s#]*$');

/// 整行只有一段粗体(`**AI 助手**`)—— 发版时拿它当分组小标题用。
final _boldLine = RegExp(r'^\*\*([^*]+)\*\*[:：]?$');

final _item = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');

/// 分隔线 `---` / `***`,不画,只断段。
final _rule = RegExp(r'^([-*_])(\s*\1){2,}$');

final _inline = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\([^)]*\)');

/// 按行切块。GitHub 存的正文是 `\r\n`,`trimRight` 顺手去掉 `\r`。
List<NoteBlock> parseReleaseNotes(String raw) {
  final out = <NoteBlock>[];
  final para = <String>[];

  void flush() {
    if (para.isEmpty) return;
    out.add((
      kind: NoteKind.para,
      text: para.join('\n'),
      marker: '',
      indent: 0,
    ));
    para.clear();
  }

  for (final rawLine in raw.split('\n')) {
    final line = rawLine.trimRight();
    final t = line.trim();
    if (t.isEmpty || _rule.hasMatch(t)) {
      flush();
      continue;
    }
    if (_heading.firstMatch(t) case final m?) {
      flush();
      // 三级以下的标题和粗体小标题一个分量
      final kind = m[1]!.length <= 2 ? NoteKind.heading : NoteKind.sub;
      out.add((kind: kind, text: m[2]!, marker: '', indent: 0));
      continue;
    }
    if (_boldLine.firstMatch(t) case final m?) {
      flush();
      out.add((kind: NoteKind.sub, text: m[1]!, marker: '', indent: 0));
      continue;
    }
    if (_item.firstMatch(line) case final m?) {
      flush();
      final mark = m[2]!;
      out.add((
        kind: NoteKind.item,
        text: m[3]!,
        marker: RegExp(r'^\d').hasMatch(mark) ? mark : '•',
        indent: (m[1]!.length ~/ 2).clamp(0, 2),
      ));
      continue;
    }
    // 缩进写在下一行的,是上一个列表项的续行
    if (para.isEmpty &&
        line.startsWith(' ') &&
        out.isNotEmpty &&
        out.last.kind == NoteKind.item) {
      final last = out.removeLast();
      out.add((
        kind: last.kind,
        text: '${last.text}\n$t',
        marker: last.marker,
        indent: last.indent,
      ));
      continue;
    }
    para.add(t);
  }
  flush();
  return out;
}

/// 行内:粗体、代码、链接(只留文字)。
List<InlineSpan> _spans(BuildContext context, String text, TextStyle base) {
  final out = <InlineSpan>[];
  var last = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start)));
    if (m[1] != null) {
      out.add(
        TextSpan(
          text: m[1],
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      );
    } else if (m[2] != null) {
      out.add(
        TextSpan(
          text: m[2],
          style: mono(
            context,
            size: (base.fontSize ?? 12) - 0.5,
            weight: FontWeight.w500,
          ).copyWith(backgroundColor: context.scheme.surfaceContainerHighest),
        ),
      );
    } else {
      out.add(TextSpan(text: m[3]));
    }
    last = m.end;
  }
  if (last < text.length) out.add(TextSpan(text: text.substring(last)));
  return out;
}

double _gap(NoteKind prev, NoteKind cur) => switch ((prev, cur)) {
  (_, NoteKind.heading) => 16,
  (NoteKind.heading, _) => 6,
  (_, NoteKind.sub) => 12,
  (NoteKind.sub, _) => 4,
  (NoteKind.item, NoteKind.item) => 3,
  _ => 8,
};

class ReleaseNotes extends StatelessWidget {
  const ReleaseNotes(this.raw, {super.key});

  final String raw;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final body = context.texts.bodySmall!.copyWith(height: 1.55);
    final blocks = parseReleaseNotes(raw);

    Widget rich(String text, TextStyle style) => Text.rich(
      TextSpan(style: style, children: _spans(context, text, style)),
    );

    Widget block(NoteBlock b) => switch (b.kind) {
      NoteKind.heading => rich(
        b.text,
        context.texts.titleSmall!.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
      ),
      NoteKind.sub => rich(
        b.text,
        body.copyWith(fontSize: 13, fontWeight: FontWeight.w700, height: 1.4),
      ),
      NoteKind.item => Padding(
        padding: EdgeInsets.only(left: 14.0 * b.indent),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: b.marker == '•' ? 14 : 20,
              child: Text(
                b.marker,
                style: body.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(child: rich(b.text, body)),
          ],
        ),
      ),
      NoteKind.para => rich(b.text, body),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(
              top: i == 0 ? 0 : _gap(blocks[i - 1].kind, blocks[i].kind),
            ),
            child: block(blocks[i]),
          ),
      ],
    );
  }
}
