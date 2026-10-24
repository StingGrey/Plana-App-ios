import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/features/cloud_sync/cloud_sync_engine.dart';
import 'package:plana_app/features/cloud_sync/cloud_sync_progress.dart';
import 'package:plana_app/features/cloud_sync/cloud_sync_state.dart';

class _FakeSync extends CloudSyncNotifier {
  @override
  CloudSyncState build() => const CloudSyncState(supported: true);

  void set(CloudSyncState s) => state = s;
}

void main() {
  CloudSyncState running(CloudSyncPhase phase, int done, int total) =>
      CloudSyncState(
        supported: true,
        running: true,
        phase: phase,
        done: done,
        total: total,
      );

  test('进度文案按阶段说,没在同步就没有', () {
    expect(cloudSyncProgressText(const CloudSyncState()), isNull);
    expect(
      cloudSyncProgressText(running(CloudSyncPhase.checking, 0, 0)),
      '正在检查文件夹…',
    );
    expect(
      cloudSyncProgressText(running(CloudSyncPhase.uploading, 3, 20)),
      '正在上传 3 / 20',
    );
    expect(
      cloudSyncProgressText(running(CloudSyncPhase.pulling, 1, 4)),
      '正在拉取 1 / 4',
    );
    expect(
      cloudSyncProgressValue(running(CloudSyncPhase.checking, 0, 0)),
      isNull,
    );
    expect(
      cloudSyncProgressValue(running(CloudSyncPhase.uploading, 5, 20)),
      .25,
    );
    expect(cloudSyncProgressValue(const CloudSyncState()), isNull);
  });

  testWidgets('「我的」图标只在同步时挂进度角标,同步完收起', (tester) async {
    final c = ProviderContainer(
      overrides: [cloudSyncProvider.overrideWith(_FakeSync.new)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: CloudSyncTabIcon(child: Icon(Icons.person))),
          ),
        ),
      ),
    );
    expect(find.byType(Badge), findsNothing);

    final fake = c.read(cloudSyncProvider.notifier) as _FakeSync;
    fake.set(running(CloudSyncPhase.checking, 0, 0));
    await tester.pump();
    expect(find.byType(Badge), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);

    fake.set(running(CloudSyncPhase.uploading, 3, 8));
    await tester.pump();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.text('37%'), findsOneWidget);

    fake.set(running(CloudSyncPhase.pulling, 4, 4));
    await tester.pump();
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    fake.set(const CloudSyncState(supported: true));
    await tester.pump();
    expect(find.byType(Badge), findsNothing);
    expect(find.byIcon(Icons.person), findsOneWidget);
  });
}
