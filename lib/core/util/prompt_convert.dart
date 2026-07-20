/// SD WebUI ↔ NAI 提示词权重语法整串转换(移植自 web 工具箱 MobileToolsPage):
/// SD→NAI:`(x:1.05)`→`{x}`、`(x:0.95)`→`[x]`、`(x:w)`→`w::x::`、裸 `(x)`→`{x}`、
/// `\(`/`\)`→字面括号;NAI→SD:`{x}`→`(x:1.05)`、`w::x::`→`(x:w)`、
/// `[..]` 原样、字面括号转义。数字按 JS Number 字符串语义输出(整数去 .0)。
library;

/// 去除 `<lora:…>` 标签并清理残留逗号(SD→NAI 前置清洗,与 web 同款)。
String stripLoraTags(String input) {
  return input
      .replaceAll(RegExp(r'<lora:[^>]*>'), '')
      .replaceAll(RegExp(r',\s*,'), ',')
      .replaceAll(RegExp(r'^\s*,|,\s*$'), '')
      .trim();
}

String _jsNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

final _numRe = RegExp(r'^\s*-?\d+(?:\.\d+)?\s*$');

String convertSdToNai(String text) {
  final res = StringBuffer();
  var i = 0;
  final n = text.length;
  while (i < n) {
    final ch = text[i];
    if (ch == r'\' && i + 1 < n && (text[i + 1] == '(' || text[i + 1] == ')')) {
      res.write(text[i + 1]);
      i += 2;
      continue;
    }
    if (ch == '(') {
      var depth = 1;
      var j = i + 1;
      while (j < n && depth > 0) {
        if (text[j] == '(') {
          depth++;
        } else if (text[j] == ')') {
          depth--;
        }
        j++;
      }
      if (depth == 0) {
        final inner = text.substring(i + 1, j - 1);
        final lastColon = inner.lastIndexOf(':');
        if (lastColon > 0) {
          final left = inner.substring(0, lastColon);
          final right = inner.substring(lastColon + 1);
          if (_numRe.hasMatch(right)) {
            final weight = double.parse(right.trim());
            final content = convertSdToNai(left);
            if ((weight - 1.05).abs() < 0.001) {
              res.write('{$content}');
            } else if ((weight - 0.952381).abs() < 0.001 ||
                (weight - 0.95).abs() < 0.001) {
              res.write('[$content]');
            } else {
              res.write('${_jsNum(weight)}::$content::');
            }
            i = j;
            continue;
          }
        }
        res.write('{${convertSdToNai(inner)}}');
        i = j;
        continue;
      }
    } else if (ch == '[') {
      var depth = 1;
      var j = i + 1;
      while (j < n && depth > 0) {
        if (text[j] == '[') {
          depth++;
        } else if (text[j] == ']') {
          depth--;
        }
        j++;
      }
      if (depth == 0) {
        res.write('[${convertSdToNai(text.substring(i + 1, j - 1))}]');
        i = j;
        continue;
      }
    }
    res.write(ch);
    i++;
  }
  return res.toString();
}

final _naiWeightRe = RegExp(r'(-?\d+(?:\.\d+)?)::');

String convertNaiToSd(String text) {
  final res = StringBuffer();
  var i = 0;
  final n = text.length;
  while (i < n) {
    final ch = text[i];
    if (RegExp(r'\d').hasMatch(ch) || ch == '-') {
      final m = _naiWeightRe.matchAsPrefix(text, i);
      if (m != null) {
        final weight = double.parse(m.group(1)!);
        final afterNum = m.end;
        final endIdx = text.indexOf('::', afterNum);
        if (endIdx != -1) {
          res.write(
            '(${convertNaiToSd(text.substring(afterNum, endIdx))}'
            ':${_jsNum(weight)})',
          );
          i = endIdx + 2;
          continue;
        }
      }
    }
    if (ch == '{') {
      var depth = 1;
      var j = i + 1;
      while (j < n && depth > 0) {
        if (text[j] == '{') {
          depth++;
        } else if (text[j] == '}') {
          depth--;
        }
        j++;
      }
      if (depth == 0) {
        res.write('(${convertNaiToSd(text.substring(i + 1, j - 1))}:1.05)');
        i = j;
        continue;
      }
    } else if (ch == '[') {
      var depth = 1;
      var j = i + 1;
      while (j < n && depth > 0) {
        if (text[j] == '[') {
          depth++;
        } else if (text[j] == ']') {
          depth--;
        }
        j++;
      }
      if (depth == 0) {
        res.write('[${convertNaiToSd(text.substring(i + 1, j - 1))}]');
        i = j;
        continue;
      }
    }
    if (ch == '(' || ch == ')') {
      res.write('\\$ch');
      i++;
      continue;
    }
    res.write(ch);
    i++;
  }
  return res.toString();
}
