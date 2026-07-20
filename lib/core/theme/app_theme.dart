import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct, SchemeTonalSpot;

/// 全局主题。当前阶段按用户要求使用 M3 默认配色(基准种子色),
/// 组件一律走语义角色(primary/surfaceContainer* 等),
/// 将来切 NAI 品牌皮肤时只需替换这里的 ColorScheme。
abstract final class AppTheme {
  /// 默认种子色:NAI 淡金 #fceda4 的加深版(可在「外观」页切换其他种子)。
  static const Color seed = Color(0xFFD4A72C);

  static ThemeData light([Color? seedColor]) =>
      _build(Brightness.light, seedColor ?? seed);

  static ThemeData dark([Color? seedColor]) =>
      _build(Brightness.dark, seedColor ?? seed);

  static ThemeData _build(Brightness brightness, Color seedColor) {
    final scheme = _widenSurfaces(
      ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness),
      seedColor,
      brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: scheme.surfaceContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }

  /// M3 默认 surface 阶梯太贴(暗色 背景N6/卡片N10,亮色 背景N98/卡片N96),
  /// 层级观感弱。用种子的中性调色板重排一条间距更大的阶梯:
  /// 暗色 背景压深、容器逐级提亮;亮色改「灰底白卡」,容器逐级压灰。
  static ColorScheme _widenSurfaces(
    ColorScheme s,
    Color seedColor,
    Brightness brightness,
  ) {
    // 与 fromSeed 同源:默认变体 tonalSpot 的中性调色板
    final neutral = SchemeTonalSpot(
      sourceColorHct: Hct.fromInt(seedColor.toARGB32()),
      isDark: brightness == Brightness.dark,
      contrastLevel: 0.0,
    ).neutralPalette;
    Color t(int tone) => Color(neutral.get(tone));
    return brightness == Brightness.dark
        ? s.copyWith(
            surface: t(4),
            surfaceContainerLowest: t(2),
            surfaceContainerLow: t(12),
            surfaceContainer: t(18),
            surfaceContainerHigh: t(24),
            surfaceContainerHighest: t(30),
          )
        : s.copyWith(
            surface: t(96),
            surfaceContainerLowest: t(100),
            surfaceContainerLow: t(100),
            surfaceContainer: t(92),
            surfaceContainerHigh: t(89),
            surfaceContainerHighest: t(86),
          );
  }
}

/// 便捷访问
extension ThemeX on BuildContext {
  ColorScheme get scheme => Theme.of(this).colorScheme;
  TextTheme get texts => Theme.of(this).textTheme;
}

/// 等宽数字(参数读数、token 计数用)
TextStyle mono(BuildContext context,
    {double size = 12, FontWeight weight = FontWeight.w600, Color? color}) {
  return TextStyle(
    fontFamily: 'monospace',
    fontFeatures: const [FontFeature.tabularFigures()],
    fontSize: size,
    fontWeight: weight,
    color: color ?? context.scheme.onSurface,
  );
}

/// M3 动效时长/曲线的统一出口,页面内所有过渡保持一致节奏。
abstract final class Motion {
  static const Duration fast = Durations.short4; // 200ms
  static const Duration medium = Durations.medium2; // 300ms
  static const Duration slow = Durations.medium4; // 400ms
  static const Curve emphasized = Easing.emphasizedDecelerate;
  static const Curve standard = Easing.standard;
}
