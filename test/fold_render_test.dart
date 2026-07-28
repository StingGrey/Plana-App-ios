import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/widgets/rich_tag_controller.dart';

/// 折叠省空间的保证移到**模型层**:正文里根本没有折叠体(collapseFolds 把它
/// 收进旁路表,正文只剩 `<#名字>` 占位符),渲染层零布局技巧——所见即所有。
/// 此前两版「藏字」实现(fontSize 0.01 / 负 letterSpacing)在真机字形引擎上
/// 接连翻车(长折叠体撑宽换行 / 鬼缩进),这组用例钉死新架构的两条底线。
void main() {
  const longDraft =
      '<#kazutake: 1.1::kazutake_hazano::,1.3::lobelia(saclia)::,'
      '0.8::ezu (e104mjd)::,0.6::hyatsu::,0.7::dolphro-kun::,very aesthetic,'
      ' masterpiece,-2::artist collaboration::,year2025,year 2024>, newtag';

  test('正文里没有折叠体:186 字符的长折叠收成一枚短占位符', () {
    final (display, bodies) = collapseFolds(longDraft);
    expect(display, '​#kazutake​, newtag');
    expect(bodies['kazutake'], isNotNull);
    // 往返无损:展开 → 定稿与直接算草稿定稿一致
    expect(outputOf(expandFolds(display, bodies)), outputOf(longDraft));
  });

  test('measureSpan 无特殊布局:占位符按普通文本排,窄屏单行', () {
    final (display, _) = collapseFolds(longDraft);
    final base = kEditorBaseStyle.copyWith(fontSize: 16);
    final tp = TextPainter(
      text: measureSpan(display, TextScaler.noScaling, base: base),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: 360); // 手机常见正文宽
    expect(tp.computeLineMetrics().length, 1);
    // 宽度 = 占位符的诚实宽度(逐字符可见,无隐藏段)
    final plain = TextPainter(
      text: TextSpan(text: display, style: base),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: 360);
    expect((tp.width - plain.width).abs(), lessThan(0.5));
    tp.dispose();
    plain.dispose();
  });
}
