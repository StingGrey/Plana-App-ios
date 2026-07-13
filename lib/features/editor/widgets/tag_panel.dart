import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/editor_theme.dart';
import '../data/suggestions.dart' show translationOf;
import '../editor_models.dart';

/// 词条栏 / 权重面板 —— 光标右邻是本标签正文时吸在键盘上方。
/// 头部(名字·热度·翻译·复制·关闭)+ 权重(括号快捷键 · 数值加减,长按持续)
/// + 清除/关联/禁用/删除 + 关联标签(点「关联」才展开)。改动都由页面改文本落地。
class TagPanel extends StatefulWidget {
  const TagPanel({
    super.key,
    required this.tok,
    required this.count,
    required this.related,
    this.relatedLoading = false,
    required this.onWrap,
    required this.onSetMult,
    required this.onClear,
    required this.onToggleDisabled,
    required this.onDelete,
    required this.onAddRelated,
    required this.onClose,
  });

  final Tok tok;
  final int? count;
  final List<String> related;

  /// 关联标签正在异步拉取(按钮不置灰,左侧显示转圈)。
  final bool relatedLoading;

  /// 括号快捷键:套一层 {}(up=true)或 [](up=false),不动数值
  final void Function(bool up) onWrap;

  /// 数值加减:改内层 `N::tag::` 倍率
  final void Function(double mult) onSetMult;

  /// 清除权重:去括号 + 数值
  final VoidCallback onClear;
  final VoidCallback onToggleDisabled;
  final VoidCallback onDelete;
  final void Function(String tag) onAddRelated;

  /// 关闭词条栏
  final VoidCallback onClose;

  @override
  State<TagPanel> createState() => _TagPanelState();
}

class _TagPanelState extends State<TagPanel> {
  bool _relatedOpen = false; // 关联标签是否展开

  @override
  void didUpdateWidget(TagPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切到另一枚标签时收起关联(同枚改权重则保持)
    if (oldWidget.tok.name != widget.tok.name) _relatedOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final pal = context.editor;
    final tok = widget.tok;
    final on = !tok.disabled;

    final Color wc = tok.disabled
        ? scheme.onSurfaceVariant
        : tok.effMult > 1.0001
        ? pal.weightUp
        : tok.effMult < 0.9999
        ? pal.weightDown
        : scheme.onSurface;

    final hasRelated = widget.related.isNotEmpty;

    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              tok: tok,
              count: widget.count,
              wc: wc,
              onClose: widget.onClose,
            ),
            const SizedBox(height: 8),
            // 权重:括号快捷键(左)· 数值加减(右,支持长按持续步进,读数居中)
            Row(
              children: [
                Text(
                  '权重',
                  style: context.texts.bodyMedium!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                _weightBtn(
                  context,
                  '[ ]',
                  pal.weightDown,
                  scheme.onError,
                  enabled: on,
                  onTap: () => widget.onWrap(false),
                ),
                const SizedBox(width: 6),
                _weightBtn(
                  context,
                  '{ }',
                  pal.weightUp,
                  scheme.onError,
                  enabled: on,
                  onTap: () => widget.onWrap(true),
                ),
                const Spacer(),
                _RepeatBtn(
                  icon: Icons.remove,
                  enabled: on,
                  step: () => widget.onSetMult(tok.numMult - 0.1),
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    '×${fmtMult(tok.effMult)}',
                    textAlign: TextAlign.center,
                    style: mono(context, size: 16, color: wc),
                  ),
                ),
                _RepeatBtn(
                  icon: Icons.add,
                  enabled: on,
                  step: () => widget.onSetMult(tok.numMult + 0.1),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 操作:清除权重 · 关联(点开展开)· 禁用 · 删除
            Row(
              children: [
                Expanded(
                  child: _action(
                    context,
                    '清除权重',
                    enabled:
                        on &&
                        (tok.braceLevel != 0 ||
                            (tok.numMult - 1.0).abs() >= 0.005),
                    onTap: widget.onClear,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    context,
                    '关联',
                    icon: widget.relatedLoading
                        ? null
                        : (_relatedOpen
                              ? Icons.expand_less
                              : Icons.expand_more),
                    // 加载中:左侧转圈,按钮不置灰(点击暂无动作)
                    leading: widget.relatedLoading
                        ? SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        : null,
                    enabled: widget.relatedLoading || hasRelated,
                    selected: _relatedOpen,
                    onTap: widget.relatedLoading
                        ? () {}
                        : () => setState(() => _relatedOpen = !_relatedOpen),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    context,
                    tok.disabled ? '启用' : '禁用',
                    icon: tok.disabled
                        ? Icons.visibility
                        : Icons.visibility_off,
                    enabled: true,
                    onTap: widget.onToggleDisabled,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    context,
                    '删除',
                    icon: Icons.delete_outline,
                    danger: true,
                    enabled: true,
                    onTap: widget.onDelete,
                  ),
                ),
              ],
            ),
            // 关联标签:点「关联」展开一行横向滚动(定高,再多也不溢出;
            // Wrap 多行版在词多时撑破 dock 区,真机反馈弃用)
            AnimatedSize(
              duration: Motion.fast,
              curve: Motion.emphasized,
              alignment: Alignment.topCenter,
              child: (_relatedOpen && hasRelated)
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SizedBox(
                        height: 54,
                        width: double.infinity,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.related.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, i) => _relChip(
                            context,
                            widget.related[i],
                            () => widget.onAddRelated(widget.related[i]),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _weightBtn(
    BuildContext context,
    String label,
    Color bg,
    Color fg, {
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final scheme = context.scheme;
    return Material(
      color: enabled ? bg : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 46,
          height: 38,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: enabled ? fg : scheme.outlineVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    String label, {
    IconData? icon,
    Widget? leading, // 覆盖 icon 的自定义前导(如加载转圈)
    bool danger = false,
    bool selected = false,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final scheme = context.scheme;
    final fg = !enabled
        ? scheme.outlineVariant
        : selected
        ? scheme.onSecondaryContainer
        : danger
        ? scheme.error
        : scheme.onSurface;
    final bg = selected
        ? scheme.secondaryContainer
        : danger
        ? scheme.error.withValues(alpha: .10)
        : scheme.surfaceContainerHigh;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (leading != null) ...[
                leading,
                const SizedBox(width: 5),
              ] else if (icon != null) ...[
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: context.texts.bodyMedium!.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 关联 chip:英文 + 中文双行(web RelatedTagsRow 同形态),点按插入。
  Widget _relChip(BuildContext context, String tag, VoidCallback onTap) {
    final scheme = context.scheme;
    final trans = translationOf(tag);
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(11),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 13, color: scheme.primary),
                  const SizedBox(width: 3),
                  Text(
                    tag,
                    style: context.texts.bodySmall!.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (trans != null) ...[
                const SizedBox(height: 1),
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    trans,
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 头部:名字 · 热度 · 翻译 · 复制 · 关闭
class _Header extends StatelessWidget {
  const _Header({
    required this.tok,
    required this.count,
    required this.wc,
    required this.onClose,
  });

  final Tok tok;
  final int? count;
  final Color wc;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      tok.name.isEmpty ? '标签' : tok.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.titleMedium!.copyWith(
                        color: wc,
                        fontWeight: FontWeight.w700,
                        decoration: tok.disabled
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      _formatCount(count!),
                      style: mono(
                        context,
                        size: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
              if (tok.trans != null && tok.trans!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    tok.trans!,
                    style: context.texts.bodyMedium!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
        _circleIcon(
          context,
          icon: Icons.content_copy,
          onTap: () {
            Clipboard.setData(ClipboardData(text: tok.name));
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(const SnackBar(content: Text('已复制标签')));
          },
        ),
        const SizedBox(width: 4),
        _circleIcon(context, icon: Icons.close, onTap: onClose),
      ],
    );
  }

  Widget _circleIcon(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  static String _formatCount(int n) {
    if (n < 1000) return '';
    if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000).round()}k';
  }
}

/// 按住持续步进按钮:点=一步;按住≥350ms 后每 90ms 触发一次 [step],
/// 越按越快(每 5 步周期 −15ms,下限 40ms)。松手或超出按钮范围停止。
class _RepeatBtn extends StatefulWidget {
  const _RepeatBtn({
    required this.icon,
    required this.enabled,
    required this.step,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback step;

  @override
  State<_RepeatBtn> createState() => _RepeatBtnState();
}

class _RepeatBtnState extends State<_RepeatBtn> {
  Timer? _hold;
  Timer? _tick;
  int _ticks = 0;

  void _startHold() {
    _hold?.cancel();
    _tick?.cancel();
    _hold = Timer(const Duration(milliseconds: 350), () {
      HapticFeedback.selectionClick();
      _scheduleNext();
    });
  }

  void _scheduleNext() {
    if (!widget.enabled) return _stop();
    // 越按越快
    final period = (90 - (_ticks ~/ 5) * 15).clamp(40, 90);
    _tick = Timer(Duration(milliseconds: period), () {
      widget.step();
      _ticks++;
      _scheduleNext();
    });
  }

  void _stop() {
    _hold?.cancel();
    _tick?.cancel();
    _hold = null;
    _tick = null;
    _ticks = 0;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Listener(
      onPointerDown: (_) {
        if (!widget.enabled) return;
        _startHold();
      },
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.step : null,
        child: Material(
          color: scheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(
              widget.icon,
              size: 20,
              color: widget.enabled ? scheme.onSurface : scheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}
