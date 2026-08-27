import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/ui/responsive_grid.dart';

void main() {
  test('图片网格在手机保留两列并在平板扩列', () {
    expect(responsiveImageColumns(390), 2);
    expect(responsiveImageColumns(768), 4);
    expect(responsiveImageColumns(1024), 5);
    expect(responsiveImageColumns(1366), 6);
  });
}
