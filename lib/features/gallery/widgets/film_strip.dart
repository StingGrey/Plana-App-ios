import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../generate/gen_jobs.dart' show GenJob;
import '../../generate/widgets/common.dart' show StripeThumb, hintSnack;
import '../models.dart';
import 'gallery_grid_sheet.dart';
import 'result_badge_chip.dart';
import 'result_thumb.dart';
import '../../../core/util/haptics.dart';

// ---- 缩略图几何:**渲染与滚动定位共用这一组常数,谁都别再各写一份** ----
//
// 一枚条目的占位宽 = 图宽 + 内衬 2×2 + 边框 2×2。边框那 4px 极易漏算 ——
// 未选中时颜色是 transparent,肉眼看不见,但**照样占布局空间**。漏掉它
// 每张少算 4px,几十张累积上百像素,表现为自动滚动总差一截(实机反馈)。

const _thumbH = 72.0;
const _thumbPad = 2.0; // AnimatedContainer 内衬
const _thumbBorder = 2.0; // 选中环(透明时也占位)
const _thumbGap = 8.0; // ListView.separated 分隔
const _stripPadH = 12.0; // ListView 水平 padding

/// 条目在交叉轴上的完整占位高 —— 和 [_thumbSlotW] 同一套算法。
///
/// **别写死。** 原先外层 SizedBox 直接写 68,正好漏掉上面警告的那一圈边框
/// (实际占位 70),结果 ListView 给的紧约束把每张图压到 60 —— 常数说 62、
/// 屏幕上是 60,还没人发现。
const _thumbSlotH = _thumbH + (_thumbPad + _thumbBorder) * 2;

// 「›」是纯悬浮层:滚动区铺满全宽,缩略图从它底下直接穿过去,一寸不让。
const _moreSize = 44.0; // 圆钮直径
const _moreRight = 12.0; // 距右边缘

// 拖拽删除的垃圾条:浮在胶片条正上方(overlay 层,不占布局,不推画布)。
const _trashH = 54.0;
const _trashGap = 10.0; // 与胶片条的间距

/// 极端长宽比的兜底:太窄点不着,太宽一张就把条占满。
/// 两头都按 [_thumbH] 的倍数写(= 原来 40/116 对 62 的那两个比例)——
/// 写成绝对像素的话,一改高度这两个数就悄悄变成另一套比例了。
double _thumbImgW(double aspect) =>
    (_thumbH * aspect).clamp(_thumbH * .645, _thumbH * 1.871);

/// 条目在滚动轴上的完整占位宽(含内衬与边框)。
double _thumbSlotW(double aspect) =>
    _thumbImgW(aspect) + (_thumbPad + _thumbBorder) * 2;

/// 底部历史胶片条:横向缩略图(选中环 + 角标)+ 尾部「›」展开全部网格。
/// 头部插着**在跑的任务**,一条一张占位卡(逐帧预览 + 进度条),点卡片让画布
/// 跟随它,点历史缩略图切走看历史 —— 对齐 web 桌面端的占位卡交互。
/// 取消不在卡上:卡这么小,取消挨着「切换跟随」这个主手势太容易点错,
/// 它长在画布那条进度胶囊上(见 ProgressPill,web 也是放在状态条上)。
/// 长按历史图 = 把它拿起来,条上方浮出垃圾区,拖上去松手即删;
/// 拖回来或松在别处什么都不发生 —— 所以不再另弹确认。
/// 选中项变化(含画布横滑切图、从展开页跳选)时自动滚动,把选中项摆到视野中央。
class FilmStrip extends StatefulWidget {
  const FilmStrip({
    super.key,
    required this.results,
    required this.selectedId,
    required this.onSelect,
    required this.onDelete,
    this.jobs = const [],
    this.selectedJobId,
    this.onSelectJob,
  });

  final List<ResultImage> results;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  /// 拖进垃圾区后删这一张(状态与盘上文件由调用方处理)。
  final ValueChanged<String> onDelete;

  /// 在跑的任务,**已按新→旧排好**(调用方给 `GenPool.newestFirst`)。
  final List<GenJob> jobs;

  /// 画布正在跟随的任务;非空时历史图那边不显示选中环。
  final String? selectedJobId;
  final ValueChanged<String>? onSelectJob;

  @override
  State<FilmStrip> createState() => _FilmStripState();
}

class _FilmStripState extends State<FilmStrip> {
  final _sc = ScrollController();

  @override
  void initState() {
    super.initState();
    // 冷启动的选中项可能在条中段,布局完成后滚到可见
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void didUpdateWidget(FilmStrip old) {
    super.didUpdateWidget(old);
    if (old.selectedId != widget.selectedId ||
        old.results.length != widget.results.length ||
        old.jobs.length != widget.jobs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _hideTrash();
    _sc.dispose();
    super.dispose();
  }

  // ---- 拖拽删除:垃圾条走 overlay ----
  //
  // 不能把它塞进胶片条自己的 Stack 里:一来会把画布顶上去(拖到一半整屏
  // 跳一下),二来 Stack 越界的子节点根本收不到命中测试,而 DragTarget
  // 认的就是命中测试。
  //
  // 也不能让它待在手指起始位置底下 —— 长按完原地松手就删,「得拖过去」
  // 这层保险等于没有。所以摆在胶片条**正上方**:竖直行程短,又完全避开
  // 横向滚动那条轴。

  OverlayEntry? _trash;

  void _showTrash() {
    if (_trash != null) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final ob = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || ob == null) return;
    final top = box.localToGlobal(Offset.zero, ancestor: ob).dy;
    _trash = OverlayEntry(
      builder: (_) => Positioned(
        left: _stripPadH,
        right: _stripPadH,
        top: top - _trashH - _trashGap,
        height: _trashH,
        child: _TrashBand(onAccept: _dropDelete),
      ),
    );
    overlay.insert(_trash!);
  }

  void _hideTrash() {
    _trash?.remove();
    _trash = null;
  }

  void _dropDelete(String id) {
    Haptics.medium();
    widget.onDelete(id);
    if (mounted) hintSnack(context, '已删除', icon: Icons.delete_outline);
  }

  /// 把选中缩略图滚到**视野中央**。位置按渲染同款公式推算(缩略图宽 +
  /// 容器 padding 4 + 分隔 8),不去量已构建的布局 —— ListView 视野外的项
  /// 根本没建出来,量不着。
  ///
  /// 居中而非"最小滚动量刚好露出来":后者在横滑连切时会让选中项一直贴着
  /// 边缘走(看不出前后还有几张),从展开页跳选一张远处的图时也只是刚好
  /// 蹭进屏幕。首尾几张自然贴边(clamp 到滚动范围),那是应该的。
  void _reveal() {
    if (!mounted || !_sc.hasClients) return;
    final id = widget.selectedId;
    if (id == null) return;
    final i = widget.results.indexWhere((r) => r.id == id);
    if (i < 0) return;
    var x = _stripPadH;
    for (final j in widget.jobs) {
      // 在跑的任务卡都排在头部,历史图的位置要把它们让出来
      x += _thumbSlotW(_aspectOf(j.width, j.height)) + _thumbGap;
    }
    for (var k = 0; k < i; k++) {
      x += _thumbSlotW(widget.results[k].aspect) + _thumbGap;
    }
    final w = _thumbSlotW(widget.results[i].aspect);
    final vp = _sc.position.viewportDimension;
    final t = (x + w / 2 - vp / 2).clamp(0.0, _sc.position.maxScrollExtent);
    if ((t - _sc.offset).abs() < 1) return;
    _sc.animateTo(t, duration: Motion.medium, curve: Motion.emphasized);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final jobs = widget.jobs;
    final extra = jobs.length;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: SizedBox(
          height: _thumbSlotH,
          child: Stack(
            children: [
              Positioned.fill(
                child: ListView.separated(
                  controller: _sc,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: _stripPadH),
                  itemCount: widget.results.length + extra,
                  separatorBuilder: (_, _) => const SizedBox(width: _thumbGap),
                  itemBuilder: (context, i) {
                    if (i < extra) {
                      final j = jobs[i];
                      return _GenThumb(
                        job: j,
                        active: j.id == widget.selectedJobId,
                        onTap: () => widget.onSelectJob?.call(j.id),
                      );
                    }
                    final r = widget.results[i - extra];
                    return _FilmThumb(
                      result: r,
                      selected:
                          r.id == widget.selectedId &&
                          widget.selectedJobId == null,
                      onTap: () => widget.onSelect(r.id),
                      onDragStart: _showTrash,
                      onDragEnd: _hideTrash,
                    );
                  },
                ),
              ),
              // 悬浮「›」展开全部:压在缩略图之上,靠投影拉开层次
              Positioned(
                top: 0,
                bottom: 0,
                right: _moreRight,
                child: Center(
                  child: Material(
                    color: scheme.surfaceContainerHighest,
                    elevation: 4,
                    shadowColor: Colors.black.withValues(alpha: .45),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => showGalleryGrid(context),
                      child: SizedBox(
                        width: _moreSize,
                        height: _moreSize,
                        child: Icon(
                          Icons.chevron_right,
                          size: 24,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double _aspectOf(int w, int h) => (w > 0 && h > 0) ? w / h : 1.0;

/// 在跑的任务卡:逐帧预览(未到帧显斜纹)+ 底部细进度条。
/// 点卡片让画布跟随这条;active 时亮选中环。取消在画布的进度胶囊上,不在这儿。
class _GenThumb extends StatelessWidget {
  const _GenThumb({required this.job, required this.active, this.onTap});

  final GenJob job;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    const h = _thumbH;
    final aspect = _aspectOf(job.width, job.height);
    final w = _thumbImgW(aspect);
    final preview = job.preview;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? scheme.primary : Colors.transparent,
            width: _thumbBorder,
          ),
        ),
        padding: const EdgeInsets.all(_thumbPad),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (preview != null)
                  Image.memory(
                    preview,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                else
                  StripeThumb(width: w, height: h, radius: 0),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SizedBox(
                    height: 3,
                    child: LinearProgressIndicator(
                      value: job.progress, // null = 准备中,不确定动画
                      backgroundColor: Colors.black.withValues(alpha: .25),
                      valueColor: AlwaysStoppedAnimation(scheme.primary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilmThumb extends StatelessWidget {
  const _FilmThumb({
    required this.result,
    required this.selected,
    required this.onTap,
    required this.onDragStart,
    required this.onDragEnd,
  });

  final ResultImage result;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final w = _thumbImgW(result.aspect);
    return LongPressDraggable<String>(
      data: result.id,
      // 长按拖拽用的是延时识别器:按住不动到时才夺指针,一上来就横移的
      // 归列表滚动 —— 两条手势天然分得开,不用自己进竞技场调解。
      onDragStarted: () {
        Haptics.medium();
        onDragStart();
      },
      onDragEnd: (_) => onDragEnd(),
      onDraggableCanceled: (_, _) => onDragEnd(),
      feedback: _feedback(w),
      // 占位保住原来的宽度,否则拿起一张整条会往左塌一截,
      // 拖回来时又弹回去 —— 拖到哪儿了就更看不清了
      childWhenDragging: _shell(
        scheme,
        selected: false,
        child: Container(
          width: w,
          height: _thumbH,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: scheme.surfaceContainerHighest,
          ),
        ),
      ),
      child: GestureDetector(
        onTap: onTap,
        child: _shell(
          scheme,
          selected: selected,
          child: Stack(
            children: [
              ResultThumb(
                result: result,
                width: w,
                height: _thumbH,
                radius: 10,
              ),
              if (result.badge != ResultBadge.none)
                Positioned(
                  left: 4,
                  top: 4,
                  child: ResultBadgeChip(badge: result.badge),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选中环 + 内衬那层壳。**拿走后的占位也走这层** —— 两边尺寸必须同源,
  /// 否则拖起来的那一刻整条会抖一下。
  Widget _shell(
    ColorScheme scheme, {
    required bool selected,
    required Widget child,
  }) => AnimatedContainer(
    duration: Motion.fast,
    curve: Motion.standard,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: selected ? scheme.primary : Colors.transparent,
        width: _thumbBorder,
      ),
    ),
    padding: const EdgeInsets.all(_thumbPad),
    child: child,
  );

  /// 跟手的那张:略放大 + 投影,看着像从条里被拎了出来。
  /// feedback 画在 overlay 里,不在 Material 树下,所以自带一层。
  Widget _feedback(double w) => Material(
    color: Colors.transparent,
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .45),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ResultThumb(
        result: result,
        width: w * 1.12,
        height: _thumbH * 1.12,
        radius: 11,
      ),
    ),
  );
}

/// 拖拽删除的落点。浮在胶片条正上方,只在拖拽期间存在。
///
/// 悬停时整条转成 error 配色并把文案换成「松手删除」—— 松手是不可撤销的
/// 一下,得先让人看见自己正停在哪儿。
class _TrashBand extends StatefulWidget {
  const _TrashBand({required this.onAccept});

  final ValueChanged<String> onAccept;

  @override
  State<_TrashBand> createState() => _TrashBandState();
}

class _TrashBandState extends State<_TrashBand>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: Motion.medium)
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return FadeTransition(
      opacity: _c,
      // 从胶片条那头升上来,而不是凭空出现 —— 让人看出它是被这次拿起
      // 唤出来的,不是本来就在
      child: SlideTransition(
        position: _c.drive(
          Tween(
            begin: const Offset(0, .6),
            end: Offset.zero,
          ).chain(CurveTween(curve: Motion.emphasized)),
        ),
        child: DragTarget<String>(
          onAcceptWithDetails: (d) => widget.onAccept(d.data),
          builder: (context, cand, _) {
            final on = cand.isNotEmpty;
            return Material(
              color: on
                  ? scheme.errorContainer
                  : scheme.surfaceContainerHighest,
              elevation: on ? 8 : 3,
              shadowColor: Colors.black.withValues(alpha: .45),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: on ? scheme.error : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    on ? Icons.delete_forever : Icons.delete_outline,
                    size: 22,
                    color: on
                        ? scheme.onErrorContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    on ? '松手删除' : '拖到这里删除',
                    style: context.texts.bodyMedium!.copyWith(
                      fontWeight: FontWeight.w600,
                      color: on
                          ? scheme.onErrorContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
