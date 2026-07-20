import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/image_ops.dart';
import '../generate_state.dart';
import '../models.dart';
import 'common.dart';
import 'section_card.dart';

/// 选相册图设为图生图底图:解码尺寸 → 64 对齐/像素封顶改写生成分辨率 →
/// 写入状态并展开图生图面板;分辨率有变时提示一声。
/// 图生图卡「选择底图」与操作栏「底图」按钮共用。
Future<void> pickImg2ImgImage(BuildContext context, WidgetRef ref) async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (file == null || !context.mounted) return;
  final bytes = await file.readAsBytes();
  final (rw, rh) = await decodeImageSize(bytes); // 解码原始尺寸
  if (!context.mounted) return;
  final res = img2imgResolution(rw, rh); // 64 对齐 / 像素封顶
  final before = ref.read(generateProvider).params;
  ref.read(generateProvider.notifier).setImg2ImgImage(
        image: bytes,
        width: res.w,
        height: res.h,
      );
  // 底图会改写生成分辨率;和原来不同就提示一声,免得用户莫名其妙。
  if (before.width != res.w || before.height != res.h) {
    hintSnack(context, '分辨率已按底图调整为 ${res.w}×${res.h}',
        icon: Icons.aspect_ratio);
  }
}

/// 图生图:选底图(自动匹配分辨率)+ 强度/噪声滑杆 + 移除。
class Img2ImgCard extends ConsumerStatefulWidget {
  const Img2ImgCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  ConsumerState<Img2ImgCard> createState() => _Img2ImgCardState();
}

class _Img2ImgCardState extends ConsumerState<Img2ImgCard> {
  Future<void> _onPick() => pickImg2ImgImage(context, ref);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final cfg = state.img2img;
    final expanded = state.openPanels.contains(Panel.i2i);
    final hasImage = cfg?.image != null;

    return SectionCard(
      icon: Icons.image_outlined,
      title: '图生图',
      reorderIndex: widget.reorderIndex,
      badge: hasImage ? const CountBadge('1') : null,
      actions: [
        if (hasImage)
          RoundIconBtn(
            Icons.delete_outline,
            tooltip: '移除底图',
            color: context.scheme.error,
            onTap: notifier.disableImg2Img,
          ),
        RoundIconBtn(
          Icons.add,
          tooltip: hasImage ? '更换底图' : '选择底图',
          color: context.scheme.primary,
          onTap: _onPick,
        ),
      ],
      expanded: expanded && hasImage,
      onHeaderTap: () => notifier.togglePanel(Panel.i2i),
      body: !hasImage
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StripeThumb(
                      width: 90,
                      height: 118,
                      radius: 12,
                      image: cfg!.image,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          ParamSlider(
                            label: '强度 Strength',
                            value: cfg.strength,
                            min: 0.01, // 对齐 web:0 对 img2img 无效
                            max: 0.99,
                            divisions: 98, // step 0.01
                            onChanged: (v) => notifier.updateImg2Img(strength: v),
                          ),
                          const SizedBox(height: 6),
                          ParamSlider(
                            label: '噪声 Noise',
                            value: cfg.noise,
                            max: 0.99, // 对齐 web(min 0 可)
                            divisions: 99, // step 0.01
                            onChanged: (v) => notifier.updateImg2Img(noise: v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const InfoNote('底图按当前分辨率裁剪填充;强度越低越接近原图。'),
              ],
            ),
    );
  }
}
