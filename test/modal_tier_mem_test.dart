// Anima / Krea 的高级设置按**档位**记忆(GenParams.modalMem)。
//
// anima 四档、krea 两档共用同一组字段(生效的永远是当前这档),所以切档必须
// 有地方安放上一档调好的值。此前 setModel 每次都无条件套档位配方,于是:
// 「Turbo 拉到 20 步 → 回 NAI 看一眼 → 切回 Turbo」步数就回 12 了,在模型
// 弹层里点一下当前这档也一样 —— 用户视角就是「非 NAI 模型的高级设置根本不存」。
//
// 联动的初衷(切到慢档别还挂着蒸馏档的 12 步 CFG1 出糊图)由「**没进过**的档
// 才套官方配方」保住,所以这里既验「记得住」也验「第一次进套配方」。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/blob_store.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/state_codec.dart';

/// 临时根目录 + 用完删(Windows 句柄释放有延迟,删不掉就留给系统清)。
Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('plana_modal_mem');
  addTearDown(() async {
    for (var i = 0; i < 10; i++) {
      try {
        root.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  return root;
}

Future<GenerateNotifier> _notifier() async {
  final stores = await AppStores.open(rootOverride: _tempRoot());
  final c = ProviderContainer(
    overrides: [appStoresProvider.overrideWithValue(stores)],
  );
  addTearDown(c.dispose);
  return c.read(generateProvider.notifier);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('切走再切回:该档调过的采样参数原样还在', () async {
    final gen = await _notifier();
    gen.setModel('Anima Turbo');
    gen.applyParams(
      gen.state.params.copyWith(animaSteps: 20, animaSampler: 'uni_pc'),
    );

    // 绕一圈 NAI 再回来(最常见的那条路:切回去对比一张)
    gen.setModel('NAI 4.5 Full');
    gen.setModel('Anima Turbo');
    expect(gen.state.params.animaSteps, 20);
    expect(gen.state.params.animaSampler, 'uni_pc');

    // 在弹层里点中当前这档(picker 对当前项照样回调 setModel)
    gen.setModel('Anima Turbo');
    expect(gen.state.params.animaSteps, 20);
  });

  test('头一次进某档套官方配方;各档各记各的', () async {
    final gen = await _notifier();
    gen.setModel('Anima Turbo');
    gen.applyParams(gen.state.params.copyWith(animaSteps: 20));

    // 没进过的 Base:套该档配方,不是把 Turbo 那 20 步带过去
    gen.setModel('Anima Base');
    final base = animaTierDefaults('base');
    expect(gen.state.params.animaSteps, base.steps);
    expect(gen.state.params.animaCfg, base.cfg);
    gen.applyParams(gen.state.params.copyWith(animaSteps: 44));

    // 两档各自记住自己那份
    gen.setModel('Anima Turbo');
    expect(gen.state.params.animaSteps, 20);
    gen.setModel('Anima Base');
    expect(gen.state.params.animaSteps, 44);
  });

  test('krea 两档同理,且与 anima 同名档位互不串味', () async {
    final gen = await _notifier();
    gen.setModel('Krea 2 Raw');
    gen.applyParams(gen.state.params.copyWith(kreaSteps: 24, kreaCfg: 5.0));

    gen.setModel('Krea 2 Turbo');
    final turbo = kreaTierDefaults('turbo');
    expect(gen.state.params.kreaSteps, turbo.steps);
    gen.setModel('Krea 2 Raw');
    expect(gen.state.params.kreaSteps, 24);
    expect(gen.state.params.kreaCfg, 5.0);

    // anima 也有个 turbo 档:两条渠道的记忆键带前缀,不会互相覆盖
    gen.setModel('Anima Turbo');
    gen.applyParams(gen.state.params.copyWith(animaSteps: 7));
    gen.setModel('Krea 2 Turbo');
    expect(gen.state.params.kreaSteps, turbo.steps);
    gen.setModel('Anima Turbo');
    expect(gen.state.params.animaSteps, 7);
  });

  test('切模型只动当前渠道那套,NAI 的步数/CFG 一直不受影响', () async {
    final gen = await _notifier();
    gen.applyParams(gen.state.params.copyWith(steps: 33, cfg: 6.5));
    gen.setModel('Anima Base');
    gen.setModel('Krea 2 Turbo');
    gen.setModel('NAI 5.0 Full');
    expect(gen.state.params.steps, 33);
    expect(gen.state.params.cfg, 6.5);
  });

  test('档位记忆随工作台落盘回环;半套/脏数据整条丢弃', () async {
    final blobs = BlobStore(_tempRoot());
    var s = GenerateState.initial();
    s = s.copyWith(
      params: s.params
          .copyWith(model: 'Anima Turbo', animaSteps: 20)
          .rememberModalSampling(),
    );
    final enc = await encodeGenerateState(s, blobs);
    final back = await decodeGenerateState(enc.json, blobs);
    expect(back.params.modalMem['anima:turbo']?.steps, 20);

    // 缺 sampler 的那条不要:半套参数还原出去是给服务端传空串,比忘掉更难查
    final dirty = Map<String, dynamic>.from(enc.json);
    dirty['params'] = {
      ...dirty['params'] as Map<String, dynamic>,
      'modalMem': {
        'anima:turbo': {'steps': 20, 'cfg': 1.0, 'scheduler': 'simple'},
        'krea:raw': {
          'steps': 30,
          'cfg': 3.0,
          'sampler': 'er_sde',
          'scheduler': 'simple',
        },
      },
    };
    final loaded = await decodeGenerateState(dirty, blobs);
    expect(loaded.params.modalMem.containsKey('anima:turbo'), isFalse);
    expect(loaded.params.modalMem['krea:raw']?.steps, 30);
  });
}
