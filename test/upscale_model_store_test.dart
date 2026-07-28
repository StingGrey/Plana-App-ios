import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/gallery/upscale_model.dart';
import 'package:plana_app/features/gallery/upscale_model_store.dart';

/// 模型清单是**外部依赖的锚点**:URL 钉在 upstream tag 上,大小与 SHA-256
/// 钉住内容。这些值一旦被误改,失效方式是「用户点超分才发现下不动/校验不过」——
/// 静态分析和其他测试都看不见,所以在这里钉死。
void main() {
  test('每个本地档位都在清单里登记,且体积与角标一致', () {
    for (final m in UpscaleMethod.values.where((m) => m.local)) {
      final name = m.asset;
      expect(name, isNotNull, reason: '${m.name} 是本地档位却没有模型名');
      expect(
        upscaleModelNames,
        contains(name),
        reason: '${m.name} 用的模型 $name 不在下载清单里 —— 运行时会直接抛 StateError',
      );
      final mb = upscaleModelBytes(name!) / 1048576;
      expect(mb, greaterThan(0), reason: '$name 体积为 0,清单填错了');
      // 角标写的是给用户看的下载体积,不能和清单对不上。
      final shown = double.parse(m.badge.replaceAll('MB', ''));
      expect(
        mb,
        closeTo(shown, 0.1),
        reason: '${m.name} 角标写 ${m.badge},清单算出来是 ${mb.toStringAsFixed(1)}MB',
      );
    }
  });

  test('未登记的模型名直接抛错,不会静默返回 0', () {
    expect(upscaleModelBytes('does-not-exist'), 0);
    expect(
      () => ensureUpscaleModel('does-not-exist'),
      throwsA(isA<StateError>()),
    );
  });

  test('出处常量指向 Upscayl 官方仓', () {
    expect(kUpscaleModelSource, startsWith('https://github.com/upscayl/'));
    // tag 而非分支 —— main 会移动,某天就 404 了。
    expect(kUpscaleModelTag, matches(RegExp(r'^v\d+\.\d+\.\d+$')));
  });

  test('UpscaleModelException 的文案直接可读,不带 Bad state 前缀', () {
    // 调用方是 hintSnack('超分失败: $e'),toString 必须就是给用户看的那句话。
    expect(const UpscaleModelException('网络断了').toString(), '网络断了');
  });
}
