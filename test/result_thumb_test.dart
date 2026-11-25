import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_thumb.dart';

void main() {
  Future<Image> pumpThumb(WidgetTester tester, {required bool original}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStoresProvider.overrideWithValue(AppStores.ephemeral())],
        child: MaterialApp(
          home: Scaffold(
            body: ResultThumb(
              result: const ResultImage(
                id: 'history-test',
                width: 832,
                height: 1216,
                seed: 1,
              ),
              width: 158,
              height: 218,
              fit: original ? BoxFit.contain : BoxFit.cover,
              useOriginal: original,
            ),
          ),
        ),
      ),
    );
    return tester.widget<Image>(find.byType(Image));
  }

  GalleryThumbImage source(Image img) =>
      (img.image as ResizeImage).imageProvider as GalleryThumbImage;

  testWidgets('平板历史缩略图读取原图而非方形裁切图', (tester) async {
    final img = await pumpThumb(tester, original: true);
    expect(source(img).original, isTrue);
    expect(img.fit, BoxFit.contain);
  });

  testWidgets('网格/胶片条照旧读方形缩略图', (tester) async {
    final img = await pumpThumb(tester, original: false);
    expect(source(img).original, isFalse);
    expect(img.fit, BoxFit.cover);
  });
}
