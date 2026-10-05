// LoRA 后台下载:装好的那一刻 LoRA 卡不在(切去了没有 LoRA 模块的 NAI 画布 /
// 模型),那一条没人接,占位条会一直停在「下载中」。卡片回来时要把队列里没
// 收尾的补上。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/lora_card.dart';
import 'package:plana_app/features/lora/lora_install_queue.dart';

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async => const BotSession(sessionId: 's');
}

class _Backend extends BackendClient {
  _Backend() : super('http://test');

  @override
  Future<List<LoraCardInfo>> listLoras(
    String sessionId, {
    String base = 'anima',
  }) async => const [LoraCardInfo(name: 'lr-7', displayName: '水彩')];
}

/// 卡片不在时就装好了的那一条,还留在队列里。
class _Queue extends LoraInstallQueue {
  @override
  List<LoraInstallJob> build() => const [
    LoraInstallJob(
      versionId: 7,
      name: '水彩',
      status: LoraInstallStatus.done,
      lrId: 'lr-7',
    ),
  ];
}

void main() {
  testWidgets('装好时卡片不在:卡片回来后占位条照样转正', (tester) async {
    final c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        botSessionProvider.overrideWith(_Session.new),
        backendClientProvider.overrideWithValue(_Backend()),
        loraInstallQueueProvider.overrideWith(_Queue.new),
      ],
    );
    addTearDown(c.dispose);
    final gen = c.read(generateProvider.notifier);
    gen.setModel('Anima Turbo');
    gen.applyLoraSelection([
      ActiveLora(
        name: pendingLoraKey(7),
        displayName: '水彩',
        pending: const LoraPending(versionId: 7),
      ),
    ]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: LoraCard())),
        ),
      ),
    );
    await tester.pump(); // 首帧之后补接
    await tester.pump();
    expect(c.read(generateProvider).loras.single.name, 'lr-7');
    expect(c.read(generateProvider).loras.single.pending, isNull);
    expect(c.read(loraInstallQueueProvider), isEmpty);
    await tester.pump(const Duration(seconds: 5)); // 提示条自己收掉
  });
}
