import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/nai_credential_login.dart';
import '../../core/auth/token_probe.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/backend_config.dart';
import '../../core/net/nai_client.dart';
import '../../core/theme/app_theme.dart';
import '../editor/data/completion_source.dart';
import '../generate/widgets/common.dart'
    show confirmDialog, hintSnack, sharedAxisRoute;
import '../onboarding/bot_auth_page.dart';
import 'widgets/credential_login_sheet.dart';
import 'widgets/token_status.dart';
import '../../core/util/haptics.dart';

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

  /// Token 账户状态(会员档位 + Anlas):输入像样的令牌就防抖直查,
  /// 不等保存(相当于保存前的在线校验);进页灌入已存令牌同样触发。
  late final TokenProbe _probe = TokenProbe(
    (t) => ref.read(naiClientProvider).subscription(t),
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _probe.addListener(_onProbe);
  }

  void _onProbe() {
    if (mounted) setState(() {});
  }

  void _onChanged() {
    setState(() {});
    _probe.input(_controller.text);
  }

  @override
  void dispose() {
    _probe
      ..removeListener(_onProbe)
      ..dispose();
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
    // 手动换令牌 = 用户自己管理凭证:必须作废账号密码登录留下的续期凭证,
    // 否则日后自动续期会拿旧账号的 key 把令牌悄悄换回旧账号。
    await ref.read(accessKeyProvider.notifier).clear();
    if (!mounted) return;
    setState(() => _saving = false);
    FocusScope.of(context).unfocus();
    final err = ref.read(tokenProvider).hasError;
    Haptics.selection();
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
    await ref.read(accessKeyProvider.notifier).clear(); // 续期凭证一并清
    if (!mounted) return;
    _controller.clear();
    _probe.reset();
    Haptics.medium();
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

  /// 邮箱密码登录:sheet 里已完成换 JWT + 落盘,这里只回填输入框 ——
  /// 回填触发 probe 查档位,且输入与存档一致,按钮自然呈「清除」态。
  Future<void> _credentialLogin() async {
    final jwt = await showCredentialLoginSheet(context);
    if (jwt == null || !mounted) return;
    _controller.text = jwt;
    _controller.selection = TextSelection.collapsed(offset: jwt.length);
    _snack('已登录,令牌有效期 30 天,到期自动换新');
  }

  void _snack(String msg) => hintSnack(context, msg);

  Future<void> _selectMode(AuthMode m) async {
    if (m == ref.read(authModeProvider).value) return;
    await ref.read(authModeProvider.notifier).set(m);
    // 不再自动跳授权页:Bot 卡常驻在下方,选了没配也会在卡内直接标红提示。
  }

  /// Token 卡里的账户状态行:档位 + Anlas。查询中/失败/空态都占同一行位,
  /// 状态出现或消失不改卡片高度。
  Widget _accountLine(BuildContext context) => tokenStatusLine(
    context,
    _probe,
    onRetry: () => _probe.run(_controller.text),
  );

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
    Haptics.medium();
    hintSnack(context, '已解除授权', icon: Icons.check_circle_outline);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tokenProvider);
    // 载入完成后把已存令牌灌入输入框一次(之后交给用户编辑)。
    if (!_seeded && async.hasValue) {
      // 灌入触发 listener → 走输入即查的同一条防抖链
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
            // 有存档且未改动 → 按钮化身红底「清除」
            showClear: hasSaved && !dirty && !_saving,
            saving: _saving,
            onToggleObscure: () => setState(() => _obscure = !_obscure),
            onPaste: _paste,
            onSave: _save,
            onClear: _clear,
            onCredentialLogin: _credentialLogin,
            accountLine: _accountLine(context),
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
    required this.showClear,
    required this.saving,
    required this.onToggleObscure,
    required this.onPaste,
    required this.onSave,
    required this.onClear,
    required this.onCredentialLogin,
    required this.accountLine,
  });

  final TextEditingController controller;
  final bool obscure;
  final bool hasSaved;
  final bool canSave;

  /// true = 同一颗按钮化身红底「清除」(有存档且输入未改动)。
  final bool showClear;
  final bool saving;
  final VoidCallback onToggleObscure;
  final VoidCallback onPaste;
  final VoidCallback onSave;
  final VoidCallback onClear;

  /// 打开邮箱密码登录弹层(没有令牌也能接入的路)。
  final VoidCallback onCredentialLogin;

  /// 账户状态行(会员档位 · Anlas / 查询中 / 失败重试 / 空占位)。
  final Widget accountLine;

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
            const SizedBox(height: 4),
            // 直连由本机直打 api.novelai.net,不经过 Bot 后端中转:网络到不了
            // 官网,令牌再对也生成不了。
            Text(
              '直连生成需要你的网络可以访问 NovelAI 官网',
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
                hintText: '粘贴 pst-… 令牌或网页 eyJ… JWT',
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
            // 左边两行(账户状态 / 隐私说明),右边一颗随状态变身的按钮:
            // 有改动 → 保存;与存档一致 → 红底清除
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      accountLine,
                      const SizedBox(height: 2),
                      Text(
                        '仅加密存储在本机',
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: showClear ? onClear : (canSave ? onSave : null),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(96, 44),
                    backgroundColor: showClear ? scheme.error : null,
                    foregroundColor: showClear ? scheme.onError : null,
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
                      : Text(showClear ? '清除' : '保存'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onCredentialLogin,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                icon: const Icon(Icons.mail_outline, size: 16),
                label: const Text('没有令牌?用邮箱密码登录'),
              ),
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
            // 缺凭据的警告直接顶替常驻说明的位置(同一行槽,高度不变)
            Text(
              missing
                  ? (mode == AuthMode.token
                        ? '尚未保存 Token,当前无法生成'
                        : '尚未授权 Bot,当前无法生成')
                  : (mode == AuthMode.token
                        ? '使用你的 NovelAI 账户生成图片'
                        : '使用 Bot 账户生成图片,需按月结算费用'),
              style: context.texts.labelSmall!.copyWith(
                color: missing ? scheme.error : scheme.outline,
              ),
            ),
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
  const _CompletionCard({required this.source, required this.onSelect});

  final CompletionSource source;
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
                  // 不再按 Bot 授权置灰:补全那几个接口都是公开的,
                  // 无会话只是少了画师串/OC 两组(私有数据,fail-soft 返空)。
                  const ButtonSegment(
                    value: CompletionSource.enhanced,
                    label: Text('增强补全'),
                    icon: Icon(Icons.auto_awesome, size: 16),
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
