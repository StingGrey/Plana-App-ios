import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/anlas_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/param_input.dart';
import '../cost.dart';
import '../gen_modules.dart';
import '../generate_state.dart';
import '../generation_controller.dart';
import '../loop_controller.dart';
import '../models.dart' show stepsRangeOf;
import '../vibe_encoder.dart';
import '../../import/import_panel.dart';
import 'advanced_sheet.dart';
import 'common.dart' show hintSnack;
import 'loop_sheet.dart';
import 'resolution_sheet.dart';

/// 步数滑杆的开合 + 拖动草稿。
///
/// 滑杆本体浮在创作页列表上([StepsSliderOverlay]),开关是吸底栏里的读数按钮,
/// 两处不在同一子树,靠这个 provider 连。滑杆**不能**塞进吸底栏——那样整条
/// 灰底会跟着一起抬高,不是「浮动」。
///
/// 拖动期间只写 [draft]:每帧改全局参数会连着整页和费用估算一起重建,读数与
/// 费用两个 AnimatedSwitcher 每帧重新起转,肉眼就是抖。松手才提交一次。
class StepsSliderState {
  const StepsSliderState({this.open = false, this.draft});

  final bool open;
  final int? draft;
}

final stepsSliderProvider =
    NotifierProvider<StepsSliderNotifier, StepsSliderState>(
      StepsSliderNotifier.new,
    );

class StepsSliderNotifier extends Notifier<StepsSliderState> {
  @override
  StepsSliderState build() => const StepsSliderState();

  void toggle() => state = StepsSliderState(open: !state.open);
  void drag(int v) => state = StepsSliderState(open: state.open, draft: v);
  void endDrag() => state = StepsSliderState(open: state.open);
}

/// 吸底操作栏:参数读数 chips + 循环伴钮 + 生成主按钮
class BottomActionBar extends ConsumerStatefulWidget {
  const BottomActionBar({super.key});

  @override
  ConsumerState<BottomActionBar> createState() => _BottomActionBarState();
}

class _BottomActionBarState extends ConsumerState<BottomActionBar> {
  /// 上一次算出的 Vibe 编码费。改 IE / 换模型都会生成新的查询键,新键从
  /// loading 起步、取值为 null —— 直接落 0 会让费用在「免费 ⇄ N」之间反复跳
  /// (快速改 IE 时肉眼可见地闪)。查缓存本就是毫秒级,沿用上次的值更稳。
  int _lastVibeFee = 0;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(generateProvider);
    final scheme = context.scheme;
    final p = state.params;
    final gen = ref.watch(genStatusProvider);
    final pool = ref.watch(generationProvider);
    final loop = ref.watch(loopStatusProvider);

    final isOpus = ref.watch(anlasProvider).asData?.value?.isOpus ?? false;
    // 成本按实际会发送的内容估:隐藏模块的数据不发也不计
    final mods =
        ref.watch(genModulesProvider).value ?? const GenModuleSettings();
    final sent = stripHiddenModules(state, mods);
    // 编码费单列:与 estimateCost 里的「第 5 张起 +2」是两笔钱,漏算会让新加
    // 一张 Vibe 时按钮写「免费」而实扣 2 点。异步查缓存,结果没到就沿用上次
    // (见 _lastVibeFee),避免费用在参数连改时来回跳。
    final fee = ref.watch(vibeEncodeFeeProvider(vibeEncodeFeeKey(sent))).value;
    if (fee != null) _lastVibeFee = fee;
    final totalCost =
        estimateCost(sent, isOpus: isOpus) + (fee ?? _lastVibeFee);

    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _ReadoutChip(
                  caption: '尺寸',
                  value: '${p.width}×${p.height}',
                  onTap: () => showResolutionSheet(context),
                ),
                const SizedBox(width: 8),
                const _StepsChip(),
                const Spacer(),
                _ReadoutChip(
                  icon: Icons.tune,
                  value: '高级',
                  valueMuted: true,
                  onTap: () => showAdvancedSheet(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                // 导入图片:选相册图 → 解析元数据/用作参考的全屏导入面板
                Tooltip(
                  message: '导入图片',
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: .9),
                        width: 1.5,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(15),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => openImportPanel(context),
                        child: Center(
                          child: Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 22,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                // 循环伴钮:进循环面板(选张数并开始);运行中高亮,面板里可停
                Tooltip(
                  message: '循环生成',
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: loop.active
                          ? scheme.primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: loop.active
                            ? scheme.primary
                            : scheme.outline.withValues(alpha: .9),
                        width: 1.5,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(15),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => showLoopSheet(context),
                        child: Center(
                          child: Icon(
                            Icons.autorenew,
                            size: 22,
                            color: loop.active
                                ? scheme.onPrimaryContainer
                                : scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                // 生成主按钮。**并行之后它一直是「生成」**:再点就是再投一条。
                // 有任务在跑时按钮**内部**右侧长出一段停止区(带进度环)——
                // 创作页看不见图库的任务卡,没它就整页看不到进度、也没处取消。
                Expanded(
                  child: _GenerateButton(
                    cost: totalCost,
                    onGenerate: () {
                      _hintDisabledVibes(context, ref);
                      ref.read(generationProvider.notifier).generate();
                    },
                    progress: pool.busy ? gen.progress : null,
                    runningCount: pool.busy ? pool.jobs.length : 0,
                    stopIcon: loop.active && !loop.stopping
                        ? Icons.stop_rounded
                        : Icons.close_rounded,
                    // 循环:第一次点=软停(本张跑完后停),**再点一次=强制取消**。
                    // 软停后绝不能变成 null —— 那会在当前张卡住时(断网最常见)
                    // 关掉唯一的退路,只能干等超时。实测反馈。
                    onStop: loop.active && !loop.stopping
                        ? () => ref.read(loopStatusProvider.notifier).stop()
                        : () => ref.read(generationProvider.notifier).cancel(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 生成/排队前置检查:缺当前模型编码的纯编码 Vibe 无从现场编码,
/// 只会被静默跳过——直接停用并提示,别让人误以为它生效了。
void _hintDisabledVibes(BuildContext context, WidgetRef ref) {
  final n = ref.read(generateProvider.notifier).disableVibesMissingEncoding();
  if (n > 0) {
    hintSnack(
      context,
      '$n 个 Vibe 缺当前模型编码,已停用',
      icon: Icons.visibility_off_outlined,
    );
  }
}

/// 生成主按钮。有任务在跑时**按钮内部**右侧展开一段停止区:
/// 环 = 画布正跟随那条的进度(与图库画布上的进度胶囊同一条口径,不是全池平均
/// —— 平均值谁也对不上号),多条在跑时环里标数。
///
/// 做成一颗按钮而不是两颗并排:并排那版把主按钮挤窄了一截,而且「生成」和
/// 「停止」是同一件事的两面,分开两个方块反而要多想一下哪个是哪个。
class _GenerateButton extends StatelessWidget {
  const _GenerateButton({
    required this.cost,
    required this.onGenerate,
    required this.progress,
    required this.runningCount,
    required this.stopIcon,
    required this.onStop,
  });

  final int cost;
  final VoidCallback onGenerate;

  /// 跟随那条的进度;null = 还没出图(走不确定动画)。
  final double? progress;

  /// 在跑的条数;0 = 不显示停止区。
  final int runningCount;
  final IconData stopIcon;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final busy = runningCount > 0;
    return SizedBox(
      height: 52,
      child: Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(26),
        clipBehavior: Clip.antiAlias,
        // stretch:两段都要撑满 52 的高度。默认的 center 会让 InkWell 只拿到
        // 内容那点自然高度(≈28),按钮看着一大颗、实际只有中间一条窄带能点 ——
        // 表现就是「只有文字上点得动」。实测反馈。
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: InkWell(
                onTap: onGenerate,
                // 费用数字变长(编码费叠加后可到三位数)时这一行会顶破按钮 ——
                // 实测快速改 IE 会看到溢出围栏。两段文本都收进 Flexible +
                // 省略号,宁可挤扁不越界。
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 池子里已经有任务 → 换成加号:这一下是「再加一条」,
                    // 不是「开始生成」,图标得说清楚。
                    Icon(
                      busy ? Icons.add_rounded : Icons.auto_awesome,
                      size: busy ? 22 : 20,
                      color: scheme.onPrimary,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '生成',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleMedium!.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: Motion.fast,
                        child: _PillChip(key: ValueKey(cost), cost: cost),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (busy) ...[
              // 竖细线:两段是两个可点区域,没有分界的话点哪儿全靠猜。
              // 包一层 Center —— 外层是 stretch,不包的话这道线会被撑到通高。
              Center(
                child: Container(
                  width: 1,
                  height: 30,
                  color: scheme.onPrimary.withValues(alpha: .28),
                ),
              ),
              Tooltip(
                message: runningCount > 1
                    ? '取消当前跟随的这条($runningCount 条在跑)'
                    : '取消生成',
                child: InkWell(
                  onTap: onStop,
                  child: SizedBox(
                    width: 58,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 2.5,
                            backgroundColor: scheme.onPrimary.withValues(
                              alpha: .28,
                            ),
                            valueColor: AlwaysStoppedAnimation(
                              scheme.onPrimary,
                            ),
                          ),
                        ),
                        Icon(stopIcon, size: 18, color: scheme.onPrimary),
                        if (runningCount > 1)
                          Positioned(
                            right: 6,
                            top: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.onPrimary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '$runningCount',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.primary,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 主按钮内的成本胶囊。
///
/// 「Anlas」这个词砍掉换成顶栏同款点数图标(重绘 CTA 早就这么做了,见
/// inpaint_overlay):按钮内部现在还要分一段给停止区,最长的那个词首先该让位,
/// 四位数也不必再靠省略号救。免费档保留中文 —— 一个图标表达不了「不要钱」。
class _PillChip extends StatelessWidget {
  const _PillChip({super.key, required this.cost});

  final int cost;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: scheme.onPrimary,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.onPrimary.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(9),
      ),
      child: cost == 0
          ? Text('免费', maxLines: 1, softWrap: false, style: style)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.toll, size: 12, color: scheme.onPrimary),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    '$cost',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: style,
                  ),
                ),
              ],
            ),
    );
  }
}

/// 步数读数按钮:点开/收起浮动滑杆。拖动中显示草稿值(全局参数松手才变),
/// 所以按钮上的数字和滑杆上的始终一致。
class _StepsChip extends ConsumerWidget {
  const _StepsChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只订阅这一个数:拖动时不牵动整条栏重算成本
    final committed = ref.watch(
      generateProvider.select((s) => s.params.activeSteps),
    );
    final slider = ref.watch(stepsSliderProvider);
    return _ReadoutChip(
      caption: '步数',
      value: '${slider.draft ?? committed}',
      active: slider.open,
      // 拖动时逐帧换数,再叠淡入淡出只会糊成一团
      animateValue: !slider.open,
      onTap: () => ref.read(stepsSliderProvider.notifier).toggle(),
    );
  }
}

/// 步数浮动滑杆。挂在创作页 Stack 顶层,浮在列表上方、吸底栏之上——不占布局,
/// 开合不会推动任何东西。视觉与重绘面板的浮动滑杆同款。
class StepsSliderOverlay extends ConsumerWidget {
  const StepsSliderOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(stepsSliderProvider.select((s) => s.open));
    return AnimatedSwitcher(
      duration: Motion.fast,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, .3),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: open ? const _StepsSliderPill() : const SizedBox.shrink(),
    );
  }
}

class _StepsSliderPill extends ConsumerWidget {
  const _StepsSliderPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    // NAI / Anima / Krea 各有一套独立步数,范围也不同(与高级面板同源)
    final range = ref.watch(
      generateProvider.select((s) => stepsRangeOf(s.params.model)),
    );
    final committed = ref.watch(
      generateProvider.select((s) => s.params.activeSteps),
    );
    final min = range.min;
    final max = range.max;
    final steps =
        (ref.watch(stepsSliderProvider.select((s) => s.draft)) ?? committed)
            .clamp(min, max);
    return GestureDetector(
      // 不透明:否则药丸空白处的拖动会穿过去滚动底下的列表
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: .85),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: .7),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .14),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Text(
              '步数',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            Expanded(
              child: SliderTheme(
                data: compactSliderTheme,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Slider(
                    value: steps.toDouble(),
                    min: min.toDouble(),
                    max: max.toDouble(),
                    // 不传 divisions:离散 Slider 会用 75ms 曲线把滑块吸到刻度,
                    // 拖起来黏手。步长(整数)就地取整。
                    onChanged: (v) =>
                        ref.read(stepsSliderProvider.notifier).drag(v.round()),
                    // 松手才写回全局:先提交再清草稿,同一帧生效,不会闪回旧值
                    onChangeEnd: (v) {
                      final p = ref.read(generateProvider).params;
                      ref
                          .read(generateProvider.notifier)
                          .applyParams(p.withActiveSteps(v.round()));
                      ref.read(stepsSliderProvider.notifier).endDrag();
                    },
                  ),
                ),
              ),
            ),
            ParamValueBox(
              text: '$steps',
              dense: true,
              onTap: () async {
                // 弹窗期间不能再动别的,提前把 notifier 和参数取好,
                // 醒来直接写 —— 不留 await 之后再摸 ref 的口子
                final notifier = ref.read(generateProvider.notifier);
                final slider = ref.read(stepsSliderProvider.notifier);
                final p = ref.read(generateProvider).params;
                final v = await showParamInput(
                  context,
                  title: '步数 Steps',
                  value: steps.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  divisions: max - min,
                );
                if (v == null) return;
                notifier.applyParams(p.withActiveSteps(v.round()));
                slider.endDrag();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadoutChip extends StatelessWidget {
  const _ReadoutChip({
    this.caption,
    this.icon,
    required this.value,
    this.valueMuted = false,
    this.active = false,
    this.animateValue = true,
    required this.onTap,
  });

  final String? caption;
  final IconData? icon;
  final String value;
  final bool valueMuted;

  /// 该读数的滑杆正展开着(描边高亮,与重绘面板的参数按钮同款)。
  final bool active;

  /// 数值变化是否走淡入淡出。逐帧变的值要关掉,否则一堆数字叠着糊。
  final bool animateValue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final text = Text(
      value,
      key: ValueKey(value),
      style: valueMuted
          ? context.texts.bodyMedium!.copyWith(color: scheme.onSurfaceVariant)
          : mono(context, size: 13),
    );
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          // 边框常在(不激活时透明):BoxDecoration 的边框会算进内边距,
          // 有无之间差 2px —— 只在激活时给,整行会跟着抖一下。
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? scheme.primary.withValues(alpha: .6)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
              ],
              if (caption != null) ...[
                Text(
                  caption!,
                  style: TextStyle(fontSize: 10, color: scheme.outline),
                ),
                const SizedBox(width: 5),
              ],
              if (animateValue)
                AnimatedSwitcher(duration: Motion.fast, child: text)
              else
                text,
            ],
          ),
        ),
      ),
    );
  }
}
