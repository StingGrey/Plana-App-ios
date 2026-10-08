import 'dart:convert';

/// Work tags are publication labels. Only image metadata is a generation prompt.
class AiTagPrompts {
  const AiTagPrompts(
    this.positive,
    this.negative, {
    this.source = '',
    this.negativeSource = '',
  });
  final String positive;
  final String negative;
  final String source;
  final String negativeSource;
}

String aiPlatform(Object? raw) {
  final value = raw is String ? raw.trim() : '';
  return switch (value.toLowerCase()) {
    'nai' || 'novelai' => 'NAI',
    'nai_x' || 'nai x' || 'naix' => 'NAI_X',
    'sd' || 'stable diffusion' => 'SD',
    'comfyui' => 'ComfyUI',
    '' => '未知',
    _ => value,
  };
}

Object? _decode(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } catch (_) {
    return value;
  }
}

String _text(Object? value) => value is String ? value.trim() : '';
String _promptText(Object? value) {
  final text = _text(value);
  if (_decode(text) is Map || _decode(text) is List) return '';
  return text;
}

AiTagPrompts parseAiTagPrompts(Map<String, dynamic> image) {
  final raw = _decode(image['ai_json']);
  final fallback = _text(image['prompt_text']);
  if (raw is Map) {
    final comment = _decode(raw['Comment']);
    final data = comment is Map ? comment : raw;
    final parameters = data['parameters'];
    if (parameters is String && parameters.trim().isNotEmpty) {
      return _sdPrompt(parameters);
    }
    String caption(Object? value) {
      if (value is! Map || value['caption'] is! Map) return '';
      final c = value['caption'] as Map;
      // Keep character text as part of the exported prompt; never export JSON.
      return [
        _text(c['base_caption']),
        if (c['char_captions'] is List)
          for (final ch in c['char_captions'] as List)
            if (ch is Map) _text(ch['char_caption']),
      ].where((s) => s.isNotEmpty).join(', ');
    }

    final positive = _promptText(data['prompt']).isNotEmpty
        ? _promptText(data['prompt'])
        : _text(data['positive_prompt']).isNotEmpty
        ? _text(data['positive_prompt'])
        : _text(data['positive']);
    final negative = _text(data['uc']).isNotEmpty
        ? _text(data['uc'])
        : _text(data['negative_prompt']).isNotEmpty
        ? _text(data['negative_prompt'])
        : _text(data['negativePrompt']);
    final v4p = caption(data['v4_prompt']);
    final v4n = caption(data['v4_negative_prompt']);
    if (positive.isNotEmpty ||
        negative.isNotEmpty ||
        v4p.isNotEmpty ||
        v4n.isNotEmpty) {
      return AiTagPrompts(
        v4p.isNotEmpty ? v4p : positive,
        v4n.isNotEmpty ? v4n : negative,
        source: v4p.isNotEmpty ? 'v4_prompt' : 'prompt',
        negativeSource: v4n.isNotEmpty
            ? 'v4_negative_prompt'
            : data.containsKey('uc')
            ? 'uc'
            : 'negative_prompt',
      );
    }
    final graph = _decode(raw['prompt']);
    final comfy = _comfyPrompts(graph is Map ? graph : raw);
    if (comfy.positive.isNotEmpty || comfy.negative.isNotEmpty) return comfy;
    if (_text(raw['Description']).isNotEmpty) {
      return AiTagPrompts(_text(raw['Description']), '', source: 'Description');
    }
  }
  // A workflow / malformed JSON is not prose and must never enter the editor.
  if (fallback.isNotEmpty &&
      !fallback.startsWith('{') &&
      !fallback.startsWith('[')) {
    return _sdPrompt(fallback, source: 'prompt_text');
  }
  return const AiTagPrompts('', '');
}

AiTagPrompts _sdPrompt(String raw, {String source = 'parameters'}) {
  // The final parameter line is not part of the negative prompt.
  final settings = RegExp(
    r'(?:^|\n)\s*Steps:\s*\d+\s*,',
    caseSensitive: false,
  ).firstMatch(raw);
  final text = settings == null
      ? raw.trim()
      : raw.substring(0, settings.start).trim();
  final marker = RegExp(
    r'(?:^|\n)\s*Negative prompt\s*:',
    caseSensitive: false,
  ).firstMatch(text);
  return AiTagPrompts(
    marker == null ? text : text.substring(0, marker.start).trim(),
    marker == null ? '' : text.substring(marker.end).trim(),
    source: source,
    negativeSource: 'Negative prompt',
  );
}

/// Trace only conditioning inputs. Arbitrary workflow strings include models,
/// paths and notes, so do not flatten every string in a ComfyUI graph.
AiTagPrompts _comfyPrompts(Map graph) {
  final nodes = <String, Map>{};
  final links = <String, String>{};
  final workflow = graph['nodes'] is List;
  if (workflow) {
    for (final n in graph['nodes'] as List) {
      if (n is Map && n['mode'] != 2) nodes['${n['id']}'] = n;
    }
    for (final link
        in (graph['links'] is List ? graph['links'] as List : const [])) {
      if (link is List && link.length >= 3) links['${link[0]}'] = '${link[1]}';
      if (link is Map) links['${link['id']}'] = '${link['origin_id']}';
    }
  } else {
    for (final e in graph.entries) {
      if (e.value is Map && (e.value as Map).containsKey('class_type')) {
        nodes['${e.key}'] = e.value;
      }
    }
  }
  Map<String, Object?> inputs(Map n) => n['inputs'] is Map
      ? Map<String, Object?>.from(n['inputs'] as Map)
      : {
          for (final i
              in (n['inputs'] is List ? n['inputs'] as List : const []))
            if (i is Map && i['link'] != null)
              '${i['name']}': links['${i['link']}'],
        };
  final positive = <String>{};
  final negative = <String>{};
  void trace(Object? edge, Set<String> out, Set<String> seen) {
    final id = edge is List && edge.isNotEmpty ? '${edge.first}' : '$edge';
    if (!seen.add(id) || seen.length > 200) return;
    final node = nodes[id];
    if (node == null) return;
    final type = '${node['type'] ?? node['class_type']}'.toLowerCase();
    final ins = inputs(node);
    if (type.contains('cliptextencode') || type.contains('textencode')) {
      for (final key in ['text', 'text_g', 'text_l', 'prompt']) {
        final value = ins[key];
        if (!workflow && value is String && value.trim().isNotEmpty) {
          out.add(value.trim());
        }
        if (value is List || (workflow && value != null)) {
          trace(value, out, seen);
        }
      }
      if (workflow && node['widgets_values'] is List) {
        for (final value in (node['widgets_values'] as List).take(
          type.contains('sdxl') ? 2 : 1,
        )) {
          if (value is String && value.trim().isNotEmpty) out.add(value.trim());
        }
      }
      return;
    }
    // Only known conditioning transforms, never model/latent/filename inputs.
    for (final e in ins.entries) {
      if (e.key.startsWith('conditioning') ||
          e.key == 'text' ||
          e.key == 'string') {
        trace(e.value, out, seen);
      }
    }
  }

  for (final n in nodes.values) {
    for (final e in inputs(n).entries) {
      if (e.key == 'positive' || e.key == 'pos') trace(e.value, positive, {});
      if (e.key == 'negative' || e.key == 'neg') trace(e.value, negative, {});
    }
  }
  return AiTagPrompts(
    positive.join(', '),
    negative.join(', '),
    source: 'ComfyUI positive',
    negativeSource: 'ComfyUI negative',
  );
}

final _extraNetwork = RegExp(
  r'<\s*(?:lora|lyco|lycoris|hypernet)\s*:[^>]*>',
  caseSensitive: false,
);
bool hasExtraNetworkTags(String text) => _extraNetwork.hasMatch(text);
String removeExtraNetworkTags(String text) => !hasExtraNetworkTags(text)
    ? text.trim()
    : text
          .replaceAll(_extraNetwork, ' ')
          .split(RegExp(r'[,，\n]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .join(', ');

/// Keep spaces, parenthesized SD weights and NAI weight groups intact.
List<String> splitGalleryPrompt(String text) {
  final tags = <String>[];
  final stack = <String>[];
  var start = 0;
  var weighted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == r'\') {
      i++;
      continue;
    }
    if (i + 1 < text.length && text.substring(i, i + 2) == '::') {
      weighted = !weighted;
      i++;
      continue;
    }
    if ('([{<'.contains(c)) stack.add(c);
    if (')]}>'.contains(c) && stack.isNotEmpty) stack.removeLast();
    if ((c == ',' || c == '，' || c == '\n') && stack.isEmpty && !weighted) {
      final tag = text.substring(start, i).trim();
      if (tag.isNotEmpty) tags.add(tag);
      start = i + 1;
    }
  }
  final tail = text.substring(start).trim();
  if (tail.isNotEmpty) tags.add(tail);
  return tags.toSet().toList();
}
