import 'package:flutter/services.dart';

/// 全局触感出口。app 内**所有**振动都从这里走,设置里一关就全静。
///
/// 用顶层可变量而不是 provider:调用点全在手势回调、拖动 update、绘制层里,
/// 很多地方压根拿不到 ref,而且触感是每帧量级的调用,不该为它去读一次 provider。
/// 开关值由 [ThemeSettings] 持久化,启动和变更时同步进来(见 main.dart)。
abstract final class Haptics {
  static bool enabled = true;

  /// 选中/切档:最轻的一下,用在滑杆落刻度、切页、开关。
  static void selection() {
    if (enabled) HapticFeedback.selectionClick();
  }

  /// 拾起/落定:比 selection 重,用在拖动排序、越过阈值。
  static void medium() {
    if (enabled) HapticFeedback.mediumImpact();
  }
}
