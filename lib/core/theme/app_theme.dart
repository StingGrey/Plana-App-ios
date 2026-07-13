import 'package:flutter/material.dart';

/// 全局主题。当前阶段按用户要求使用 M3 默认配色(基准种子色),
/// 组件一律走语义角色(primary/surfaceContainer* 等),
/// 将来切 NAI 品牌皮肤时只需替换这里的 ColorScheme。
abstract final class AppTheme {
  /// 品牌种子色:取 NAI 淡金 #fceda4 的加深版,保证 M3 推导出足够饱和的金色角色,
  /// 亮色下背景会被染成暖米黄。改这一颗即可整体换肤。
  static const Color seed = Color(0xFFD4A72C);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
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
