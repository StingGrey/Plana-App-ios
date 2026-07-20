import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/backend_config.dart';
import '../../core/theme/app_theme.dart';
import '../editor/data/completion_source.dart';
import '../generate/widgets/common.dart'
    show confirmDialog, hintSnack, sharedAxisRoute;
import '../onboarding/bot_auth_page.dart';

/// 账号与接入(我的页二级):接入方式切换、Token / Bot 凭据、标签补全来源。
class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  final _controller = TextEditingController();
  bool _seeded = false; // 已存令牌灌入输入框一次
  bool _obscure = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = _controller.text.trim();
    if (t.isEmpty) return;
    setState(() => _saving = true);
    await ref.read(tokenProvider.notifier).save(t);
    if (!mounted) return;
    setState(() => _saving = false);
    FocusScope.of(context).unfocus();
    final err = ref.read(tokenProvider).hasError;
    HapticFeedback.selectionClick();
    _snack(err ? '保存失败,请重试' : '令牌已保存');
  }

  Future<void> _clear() async {
    final ok = await confirmDialog(
      context,
      title: '清除令牌',
      message: '将从本机删除已保存的 API Token,需重新填写才能生成。',
      confirmLabel: '清除',
    );
    if (!ok) return;
    await ref.read(tokenProvider.notifier).clear();
    if (!mounted) return;
    _controller.clear();
    HapticFeedback.mediumImpact();
    _snack('已清除令牌');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim();
    if (t == null || t.isEmpty) return;
    _controller.text = t;
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  void _snack(String msg) => hintSnack(context, msg);

  Future<void> _selectMode(AuthMode m) async {
    if (m == ref.read(authModeProvider).value) return;
    await ref.read(authModeProvider.notifier).set(m);
    // 不再自动跳授权页:Bot 卡常驻在下方,选了没配也会在卡内直接标红提示。
  }

  void _openBotAuth() =>
      Navigator.of(context).push(sharedAxisRoute(const BotAuthPage()));

  Future<void> _revokeBot() async {
    final ok = await confirmDialog(
      context,
      title: '解除 Bot 授权',
      message: '将从本机删除会话,需重新授权才能用后端生成。',
      confirmLabel: '解除',
    );
    if (!ok) return;
    await ref.read(botSessionProvider.notifier).clear();
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    hintSnack(context, '已解除授权', icon: Icons.check_circle_outline);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tokenProvider);
    // 载入完成后把已存令牌灌入输入框一次(之后交给用户编辑)。
    if (!_seeded && async.hasValue) {
      _controller.text = async.value ?? '';
      _seeded = true;
    }
    final saved = async.value ?? '';
    final cur = _controller.text.trim();
    final hasSaved = saved.isNotEmpty;
    final dirty = cur != saved;
    final canSave = cur.isNotEmpty && dirty && !_saving;

    final mode = ref.watch(authModeProvider).value ?? AuthMode.token;
    final session = ref.watch(botSessionProvider).value;
    final backendUrl = ref.watch(backendBaseProvider).value ?? '';
    final compSource = ref.watch(effectiveCompletionSourceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('账号与接入')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          // 两者不是二选一:Token 与 Bot 授权各自独立配置,都可以同时存在。
          // 顶部这张只决定「付费操作走哪条路」,不再决定下面显示哪张卡。
          _RouteCard(
            mode: mode,
            onSelect: _selectMode,
            tokenReady: hasSaved,
            botReady: session != null,
          ),
          const SizedBox(height: 12),
          _TokenCard(
            controller: _controller,
            obscure: _obscure,
            hasSaved: hasSaved,
            canSave: canSave,
            saving: _saving,
            onToggleObscure: () => setState(() => _obscure = !_obscure),
            onPaste: _paste,
            onSave: _save,
            onClear: _clear,
          ),
          const SizedBox(height: 12),
          _BotCard(
            session: session,
            backendUrl: backendUrl,
            onAuthorize: _openBotAuth,
            onRevoke: _revokeBot,
          ),
          const SizedBox(height: 12),
          _CompletionCard(
            source: compSource,
            botLinked: session != null,
            onSelect: (s) =>
                ref.read(completionSourcePrefProvider.notifier).set(s),
          ),
        ],
      ),
    );
  }
}

class _TokenCard extends StatelessWidget {
  const _TokenCard({
    required this.controller,
    required this.obscure,
    required this.hasSaved,
    required this.canSave,
    required this.saving,
    required this.onToggleObscure,
    required this.onPaste,
    required this.onSave,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool obscure;
  final bool hasSaved;
  final bool canSave;
  final bool saving;
  final VoidCallback onToggleObscure;
  final VoidCallback onPaste;
  final VoidCallback onSave;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'NovelAI Token',
                  style: context.texts.labelMedium!.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _StatusChip(saved: hasSaved),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '获取方式:NovelAI 网站 → User Settings → Account → '
              'Get Persistent API Token',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: obscure,
              maxLines: obscure ? 1 : 3,
              minLines: 1,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              style: mono(context, size: 13),
              decoration: InputDecoration(
                filled: true,
                fillColor: scheme.surfaceContainerHigh,
                hintText: '粘贴以 pst-… 开头的令牌',
                hintStyle: TextStyle(color: scheme.outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: onPaste,
                      icon: const Icon(Icons.content_paste, size: 20),
                      tooltip: '粘贴',
                      color: scheme.onSurfaceVariant,
                    ),
                    IconButton(
                      onPressed: onToggleObscure,
                      icon: Icon(
                        obscure ? Icons.visibility : Icons.visibility_off,
                        size: 20,
                      ),
                      tooltip: obscure ? '显示' : '隐藏',
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (hasSaved)
                  TextButton.icon(
                    onPressed: onClear,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: scheme.error,
                    ),
                    label: Text('清除', style: TextStyle(color: scheme.error)),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: canSave ? onSave : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(96, 44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  child: saving
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onPrimary,
                          ),
                        )
                      : const Text('保存'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '仅加密存储在本机',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.saved,
    this.onLabel = '已保存',
    this.offLabel = '未设置',
  });

  final bool saved;
  final String onLabel;
  final String offLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final Color bg = saved
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final Color fg = saved
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            saved ? Icons.check_circle : Icons.error_outline,
            size: 14,
            color: fg,
          ),
          const SizedBox(width: 5),
          Text(
            saved ? onLabel : offLabel,
            style: context.texts.labelMedium!.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 生成方式卡:生成 / 放大 / Vibe 编码这些**消耗 Anlas** 的操作走哪条路。
/// 只有这类操作是二选一(一次请求只能由一个账号执行);公共库、云备份、
/// 增强补全等纯后端功能只看有没有 Bot 会话,与这里的选择无关。
class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.mode,
    required this.onSelect,
    required this.tokenReady,
    required this.botReady,
  });

  final AuthMode mode;
  final ValueChanged<AuthMode> onSelect;
  final bool tokenReady;
  final bool botReady;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    // 选中的那条路没配凭据 → 现在根本生成不了,必须说破
    final missing = mode == AuthMode.token ? !tokenReady : !botReady;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '生成方式',
              style: context.texts.labelMedium!.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<AuthMode>(
                segments: const [
                  ButtonSegment(
                    value: AuthMode.token,
                    label: Text('直连 Token'),
                    icon: Icon(Icons.vpn_key, size: 16),
                  ),
                  ButtonSegment(
                    value: AuthMode.bot,
                    label: Text('使用 Bot 账户'),
                    icon: Icon(Icons.smart_toy_outlined, size: 16),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (s) => onSelect(s.first),
                showSelectedIcon: false,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              mode == AuthMode.token
                  ? '使用你的 NovelAI 账户生成图片'
                  : '使用 Bot 账户生成图片,需按月结算费用',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
            if (missing) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 15, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      mode == AuthMode.token
                          ? '尚未保存 Token,当前无法生成'
                          : '尚未授权 Bot,当前无法生成',
                      style: context.texts.labelSmall!
                          .copyWith(color: scheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 标签补全来源切换卡:增强(后端)↔ 离线词库。
/// 只看**有没有 Bot 会话**——它是纯后端功能,与生成走哪条路无关,
/// 所以自带 Token 生成的用户只要授权过 Bot,一样能用增强补全。
class _CompletionCard extends StatelessWidget {
  const _CompletionCard({
    required this.source,
    required this.botLinked,
    required this.onSelect,
  });

  final CompletionSource source;
  final bool botLinked;
  final ValueChanged<CompletionSource> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '标签补全',
              style: context.texts.labelMedium!.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<CompletionSource>(
                segments: [
                  ButtonSegment(
                    value: CompletionSource.enhanced,
                    label: const Text('增强补全'),
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    enabled: botLinked,
                  ),
                  const ButtonSegment(
                    value: CompletionSource.danbooru,
                    label: Text('离线词库'),
                    icon: Icon(Icons.storage, size: 16),
                  ),
                ],
                selected: {source},
                onSelectionChanged: (s) => onSelect(s.first),
                showSelectedIcon: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bot 授权状态卡:显示会话归属/有效期,提供 重新授权 / 解除授权。
class _BotCard extends StatelessWidget {
  const _BotCard({
    required this.session,
    required this.backendUrl,
    required this.onAuthorize,
    required this.onRevoke,
  });

  final BotSession? session;
  final String backendUrl;
  final VoidCallback onAuthorize;
  final VoidCallback onRevoke;

  static String _fmtExpiry(int? ms) {
    if (ms == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final s = session;
    final authorized = s != null;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Bot 授权',
                  style: context.texts.labelMedium!.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _StatusChip(saved: authorized, onLabel: '已授权', offLabel: '未授权'),
              ],
            ),
            const SizedBox(height: 14),
            if (authorized) ...[
              _row(context, '账号', s.botUserId ?? '—'),
              const SizedBox(height: 8),
              _row(context, '有效期至', _fmtExpiry(s.expiresAtMs)),
              const SizedBox(height: 8),
              _row(
                context,
                '后端',
                backendUrl.isEmpty ? '—' : backendUrl,
                isMono: true,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: onAuthorize,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新授权'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onRevoke,
                    icon: Icon(Icons.link_off, size: 18, color: scheme.error),
                    label: Text('解除授权', style: TextStyle(color: scheme.error)),
                  ),
                ],
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: onAuthorize,
                icon: const Icon(Icons.smart_toy_outlined, size: 18),
                label: const Text('去授权'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(23),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    bool isMono = false,
  }) {
    final scheme = context.scheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: context.texts.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: isMono
                ? mono(context, size: 13)
                : context.texts.bodyMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
          ),
        ),
      ],
    );
  }
}
