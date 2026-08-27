import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_thumb.dart';

const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGMAAQAABQAB'
    'oIJXOQAAAABJRU5ErkJggg==';

void main() {
  testWidgets('平板历史缩略图读取原图而非方形裁切图', (tester) async {
    var originalRead = false;
    var croppedThumbRead = false;
    final bytes = Uint8List.fromList(base64Decode(_png1x1));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          galleryImageProvider('history-test').overrideWith((ref) async {
            originalRead = true;
            return bytes;
          }),
          galleryThumbProvider('history-test').overrideWith((ref) async {
            croppedThumbRead = true;
            return bytes;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ResultThumb(
              result: ResultImage(
                id: 'history-test',
                width: 832,
                height: 1216,
                seed: 1,
              ),
              width: 158,
              height: 218,
              fit: BoxFit.contain,
              useOriginal: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(originalRead, isTrue);
    expect(croppedThumbRead, isFalse);
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
  });
}
