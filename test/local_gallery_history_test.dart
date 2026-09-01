import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/local_gallery/local_gallery_state.dart';
import 'package:plana_app/features/local_gallery/local_gallery_store.dart';

const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x62,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 100 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(predicate(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'generated history appears in local catalog without a second image file',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'plana_history_catalog',
      );
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });

      final stores = await AppStores.open(rootOverride: root);
      final container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(container.dispose);

      final result = container
          .read(galleryProvider.notifier)
          .addResult(
            bytes: Uint8List.fromList(_png),
            width: 832,
            height: 1216,
            seed: 42,
            input: GenerateState.initial().copyWith(prompt: '1girl, blue eyes'),
          );
      // Import immediately, while GalleryStore's atomic write is still queued:
      // the in-memory owner must still prevent a duplicate local copy.
      final immediate = await stores.localGallery.importBytes(
        Uint8List.fromList(_png),
        'export.png',
      );
      expect(immediate.isHistoryReference, isTrue);
      final local = container.read(localGalleryProvider.notifier);
      await stores.gallery.idle;
      await _waitFor(
        () => container
            .read(localGalleryProvider)
            .items
            .any((item) => item.historyId == result.id),
      );

      final item = container
          .read(localGalleryProvider)
          .items
          .singleWhere((item) => item.historyId == result.id);
      expect(item.isHistoryReference, isTrue);
      expect(item.prompt, '1girl, blue eyes');
      expect(await stores.localGallery.readImage(item.id), orderedEquals(_png));
      expect(
        Directory(
          '${root.path}/local_gallery/images',
        ).listSync().whereType<File>(),
        isEmpty,
      );
      expect(
        File('${root.path}/gallery/images/${result.id}.png').existsSync(),
        isTrue,
      );

      // Organizing the item must not turn the reference back into a copy.
      local.toggleFavorite(item.id);
      await stores.localGallery.idle;
      final organized = container
          .read(localGalleryProvider)
          .items
          .singleWhere((item) => item.historyId == result.id);
      expect(organized.isHistoryReference, isTrue);

      // Removing it from the local catalog is non-destructive: the history
      // owner and its one image file remain available and can be restored.
      await local.delete([organized.id]);
      await stores.localGallery.idle;
      expect(container.read(galleryProvider).results, hasLength(1));
      expect(container.read(localGalleryProvider).items, isEmpty);
      expect(stores.localGallery.hiddenHistoryIds, contains(result.id));
      local.restoreHistory(result.id);
      await _waitFor(
        () => container
            .read(localGalleryProvider)
            .items
            .any((item) => item.historyId == result.id),
      );

      // The reference itself is persisted and resolves through the same
      // GalleryStore after a restart.
      stores.flushNow();
      await stores.localGallery.idle;
      final restored = await AppStores.open(rootOverride: root);
      expect(restored.localGallery.initialItems.single.historyId, result.id);
      expect(
        await restored.localGallery.readImage(
          restored.localGallery.initialItems.single.id,
        ),
        orderedEquals(_png),
      );
    },
  );

  test(
    'legacy local copy migrates to a history reference and deletes only the copy',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'plana_history_migration',
      );
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });

      final stores = await AppStores.open(rootOverride: root);
      final result = ResultImage(
        id: 'gen0',
        width: 1,
        height: 1,
        seed: 7,
        bytes: Uint8List.fromList(_png),
      );
      stores.gallery.persistResult(result);
      await stores.gallery.idle;

      // Simulate the old release, whose local store owned a second copy.
      final legacy = LocalGalleryStore(root);
      await legacy.load();
      final copied = await legacy.importBytes(
        Uint8List.fromList(_png),
        'old.png',
      );
      await legacy.flush();
      expect(
        File(
          '${root.path}/local_gallery/images/${copied.fileName}',
        ).existsSync(),
        isTrue,
      );

      final migrated = LocalGalleryStore(root, historyStore: stores.gallery);
      await migrated.load();
      expect(await migrated.migrateGeneratedCopies(), 1);
      expect(migrated.initialItems.single.isHistoryReference, isTrue);
      expect(
        File(
          '${root.path}/local_gallery/images/${copied.fileName}',
        ).existsSync(),
        isFalse,
      );
      expect(
        await migrated.readImage(migrated.initialItems.single.id),
        orderedEquals(_png),
      );
    },
  );
}
