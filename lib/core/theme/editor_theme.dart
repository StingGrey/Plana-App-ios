import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 编辑器专用「实体类型」强调色。
/// 说明:正面=primary、负面=error 由 M3 语义角色天然给出;
/// 但「角色 / OC / 作品 / 加权 / 降权」是种子色无法表达的类型语义,集中定义在此扩展里,
/// 不散落到各处硬编码,将来换皮改这一处即可。
@immutable
class EditorPalette extends ThemeExtension<EditorPalette> {
  const EditorPalette({
    required this.character,
    required this.oc,
    required this.work,
    required this.weightUp,
    required this.weightDown,
    required this.cursor,
  });

  /// 角色(靛紫)· 也是光标高亮色
  final Color character;

  /// 我的 OC(绿)
  final Color oc;

  /// 作品(紫罗兰)
  final Color work;

  /// 加权 {} (橙)
  final Color weightUp;

  /// 降权 [] (蓝)
  final Color weightDown;

  /// 输入光标
  final Color cursor;

  /// 浅色变体:在浅色表面上仍清晰可辨的类型强调色(比暗色稿加深提高对比)。
  static const light = EditorPalette(
    character: Color(0xFF6750A4), // 靛紫
    oc: Color(0xFF2E7D32), // 绿
    work: Color(0xFF8E44AD), // 紫罗兰
    weightUp: Color(0xFFC7620E), // 橙
    weightDown: Color(0xFF1B66C9), // 蓝
    cursor: Color(0xFF6750A4),
  );

  @override
  EditorPalette copyWith({
    Color? character,
    Color? oc,
    Color? work,
    Color? weightUp,
    Color? weightDown,
    Color? cursor,
  }) =>
      EditorPalette(
        character: character ?? this.character,
        oc: oc ?? this.oc,
        work: work ?? this.work,
        weightUp: weightUp ?? this.weightUp,
        weightDown: weightDown ?? this.weightDown,
        cursor: cursor ?? this.cursor,
      );

  @override
  EditorPalette lerp(EditorPalette? other, double t) {
    if (other == null) return this;
    return EditorPalette(
      character: Color.lerp(character, other.character, t)!,
      oc: Color.lerp(oc, other.oc, t)!,
      work: Color.lerp(work, other.work, t)!,
      weightUp: Color.lerp(weightUp, other.weightUp, t)!,
      weightDown: Color.lerp(weightDown, other.weightDown, t)!,
      cursor: Color.lerp(cursor, other.cursor, t)!,
    );
  }
}

/// 编辑器沿用 App 浅色主题,仅注入「类型强调」扩展色(与全局一致,不再强制暗色)。
ThemeData editorTheme() {
  final base = AppTheme.light();
  return base.copyWith(extensions: const [EditorPalette.light]);
}

extension EditorPaletteX on BuildContext {
  EditorPalette get editor =>
      Theme.of(this).extension<EditorPalette>() ?? EditorPalette.light;
}
