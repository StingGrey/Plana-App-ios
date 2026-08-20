import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_mode.dart';
import '../../../core/net/anlas_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../generate_state.dart';
import '../gpu_rental.dart';
import '../models.dart' as m;
import 'rental_panel.dart';

/// 顶栏:模型选择胶囊(左)+ Anlas 余额胶囊(右)
class GenerateTopBar extends ConsumerStatefulWidget {
  const GenerateTopBar({super.key});

  @override
  ConsumerState<GenerateTopBar> createState() => _GenerateTopBarState();
}

class _GenerateTopBarState extends ConsumerState<GenerateTopBar> {
  double _refreshTurns = 0;

  Future<void> _pickModel() async {
    final current = ref.read(generateProvider).params.model;
    // anima / krea 都走服务端 Modal 后端,仅 Bot 授权模式提供
    // (对齐 web isAnimaAvailable / isKreaAvailable:token 直连模式没有服务端会话)
    final modalOk = ref.read(authModeProvider).value == AuthMode.bot;
    final picked = await showModalBottomSheet<String>(
      context: context,
      // 定高七成屏(与高级设置那张 .86 同一路数)。不按内容高:各类条目数不同,
      // 贴内容会让弹层随分类横滑抽动;而默认的 9/16 封顶在矮屏/大字号机型上
      // 又会从底部静默裁掉选项(实机反馈:部分机型最后一个模型被挡)。
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .7,
        child: _ModelSheet(
          current: current,
          groups: [
            m.GenProvider.nai,
            if (modalOk) ...[m.GenProvider.anima, m.GenProvider.krea],
          ],
          // NAI 5 预载档同样只归 bot 线:直连线 app 自己拼 NAI 载荷,只认
          // V3/V4 格式;bot 线载荷由后端构造,上线时后端适配即可。
          nai5: modalOk,
        ),
      ),
    );
    if (picked != null) ref.read(generateProvider.notifier).setModel(picked);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(generateProvider);
    final anlasValue = ref.watch(anlasProvider).asData?.value?.anlas;
    final rentalActive = ref.watch(gpuRentalProvider).active;
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Row(
        children: [
          // 模型选择
          Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(19),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _pickModel,
              child: Padding(
                padding: const EdgeInsets.only(left: 14, right: 8),
                child: SizedBox(
                  height: 42,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: Motion.fast,
                        child: Text(
                          state.params.model,
                          key: ValueKey(state.params.model),
                          style: context.texts.bodyMedium!.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.expand_more, size: 20, color: scheme.outline),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          // 右侧那个位置给谁,看当前模型花的是哪种钱:
          //  - Anima / Krea 不扣 Anlas,余额摆在那儿是个永远不动的死数 ——
          //    换成算力来源(免费共享 / 独享实例,运行中直接报计时与费用);
          //  - NAI 但实例还活着:那台在烧 ¥4/时,比余额紧急,也让位;
          //  - 其余照旧显示余额。
          // 单独取出来再判:写成 `isModal || rental.active` 会因为短路
          // 让 NAI 之外的路径**不订阅** gpuRentalProvider —— 那样冷启动时
          // 没人把它建起来,也就不会去问「我上次那台还在不在跑」。
          if (m.isModalModel(state.params.model) || rentalActive)
            const RentalSourceChip(height: 42)
          else
            // Anlas 余额
            Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(19),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  setState(() => _refreshTurns += 1);
                  ref.read(anlasProvider.notifier).refresh();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: SizedBox(
                    height: 42,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.toll, size: 17, color: scheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          anlasValue != null ? _formatAnlas(anlasValue) : '—',
                          style: mono(
                            context,
                            size: 14,
                            weight: FontWeight.w700,
                          ).copyWith(color: scheme.primary),
                        ),
                        const SizedBox(width: 6),
                        AnimatedRotation(
                          turns: _refreshTurns,
                          duration: Motion.slow,
                          curve: Motion.standard,
                          child: Icon(
                            Icons.refresh,
                            size: 16,
                            color: scheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 模型选择弹层(定高七成屏):下划线 Tab + 可左右滑的分页,每页是该大类的型号列表。
///
/// 三类平铺成一张长表要滚两屏,选型时还得先认清自己看的是哪一段;分页之后
/// 每页只有 2-4 项,一眼到底,还能直接横滑翻类。
///
/// 只列**当前可用**的大类:Anima / Krea 走服务端 Modal 后端,token 直连模式
/// 没有服务端会话,列出来也点不动 —— 摆一排点不动的 tab 比不摆更让人费解。
/// 于是只剩一类时连 Tab 条一起收走(孤零零一个 tab 是纯噪声)。
class _ModelSheet extends StatefulWidget {
  const _ModelSheet({
    required this.current,
    required this.groups,
    this.nai5 = false,
  });

  final String current;
  final List<m.GenProvider> groups;

  /// NAI 组是否追加 NAI 5 预载档(仅 Bot 授权模式)。
  final bool nai5;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet>
    with SingleTickerProviderStateMixin {
  /// 进来就停在当前型号所属的那一类;那类当前不可用(如停在 Anima 却切回了
  /// token 模式)就落到第一类 —— 停在一个选不了的分组上没有意义。
  late final TabController _tab = TabController(
    length: widget.groups.length,
    // 进来就停在当前型号所属的那一类;那类当前不可用(如停在 Anima 却切回了
    // token 模式)就落到第一类 —— 停在一个选不了的分组上没有意义。
    initialIndex: widget.groups
        .indexOf(m.providerOfModel(widget.current))
        .clamp(0, widget.groups.length - 1),
    vsync: this,
  );

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: SizedBox(
              // 定高:胶囊随分页进出,行高不能跟着变,否则切 tab 整个列表上下抽
              height: 34,
              child: Row(
                children: [
                  Text(
                    '模型',
                    style: context.texts.titleMedium!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  // 算力来源只归 Anima / Krea:滑到 NAI 页就淡出。
                  // 跟着 tab 动画走,横滑到一半时它也在半路上,不是「啪」地切换。
                  AnimatedBuilder(
                    animation: _tab.animation!,
                    builder: (context, child) {
                      final i = _tab.animation!.value.round().clamp(
                        0,
                        widget.groups.length - 1,
                      );
                      final show = widget.groups[i] != m.GenProvider.nai;
                      return AnimatedOpacity(
                        opacity: show ? 1 : 0,
                        duration: Motion.fast,
                        child: IgnorePointer(ignoring: !show, child: child),
                      );
                    },
                    child: const RentalSourceChip(),
                  ),
                ],
              ),
            ),
          ),
          // 下划线 Tab + 可左右滑的分页:不做成一排按钮,列表本身也跟着滑。
          if (widget.groups.length > 1)
            TabBar(
              controller: _tab,
              tabs: [
                for (final g in widget.groups)
                  Tab(height: 42, text: m.providerLabel(g)),
              ],
              labelColor: scheme.primary,
              unselectedLabelColor: scheme.onSurfaceVariant,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: scheme.outlineVariant.withValues(alpha: .5),
            ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [for (final g in widget.groups) _modelList(g)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelList(m.GenProvider g) => ListView(
    padding: const EdgeInsets.only(top: 4, bottom: 8),
    children: [
      for (final model in m.modelsOf(g, nai5: widget.nai5)) _modelTile(model),
    ],
  );

  Widget _modelTile(String model) {
    final desc = m.modelDescriptions[model];
    return ListTile(
      onTap: () => Navigator.pop(context, model),
      title: Text(model, style: context.texts.bodyMedium),
      // 副标题恒单行:文案本身已按一行裁,但系统字号调大/窄屏仍会折行 ——
      // 折了这张表就一页两套行高,ellipsis 兜住。
      subtitle: desc == null
          ? null
          : Text(
              desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
      trailing: model == widget.current
          ? Icon(Icons.check, size: 18, color: context.scheme.primary)
          : null,
      dense: true,
    );
  }
}

String _formatAnlas(int v) {
  final s = v.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
