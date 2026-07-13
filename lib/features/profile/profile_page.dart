import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/backend_config.dart';
import '../../core/theme/app_theme.dart';
import '../editor/data/completion_source.dart';
import '../generate/preset_manage_page.dart';
import '../generate/prompt_presets.dart';
import '../generate/widgets/common.dart'
    show InfoNote, confirmDialog, hintSnack, sharedAxisRoute;
import '../onboarding/bot_auth_page.dart';
import '../vibe_library/vibe_library.dart';
import '../vibe_library/vibe_library_page.dart';

/// 我的:当前里程碑只做「保存 API Token」,为直连 NovelAI 做准备。
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
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

  void _snack(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _selectMode(AuthMode m) async {
    if (m == ref.read(authModeProvider).value) return;
    await ref.read(authModeProvider.notifier).set(m);
    // 切到 bot 且尚未授权 → 直接进授权页
    if (m == AuthMode.bot &&
        ref.read(botSessionProvider).value == null &&
        mounted) {
      _openBotAuth();
    }
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            '我的',
            style: context.texts.headlineSmall!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
            children: [
              _ModeCard(mode: mode, onSelect: _selectMode),
              const SizedBox(height: 12),
              if (mode == AuthMode.bot)
                _BotCard(
                  session: session,
                  backendUrl: backendUrl,
                  onAuthorize: _openBotAuth,
                  onRevoke: _revokeBot,
                )
              else
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
              _CompletionCard(
                source: compSource,
                botMode: mode == AuthMode.bot,
                onSelect: (s) =>
                    ref.read(completionSourcePrefProvider.notifier).set(s),
              ),
              const SizedBox(height: 12),
              const _PresetEntryCard(),
              const SizedBox(height: 12),
              const _VibeLibraryEntryCard(),
              const SizedBox(height: 12),
              _footerNote(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _footerNote(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '外观 / 默认参数 / 备份等设置将在后续里程碑加入。',
        style: context.texts.labelSmall!.copyWith(
          color: context.scheme.outline,
        ),
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
                Icon(Icons.vpn_key, size: 20, color: scheme.primary),
                const SizedBox(width: 9),
                Text(
                  'NovelAI API Token',
                  style: context.texts.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _StatusChip(saved: hasSaved),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '直连 NovelAI 生成图像所需。在 NovelAI 网站 → User Settings → '
              'Account → Get Persistent API Token 获取,粘贴到下方。',
              style: context.texts.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
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
            const SizedBox(height: 10),
            const InfoNote('令牌加密存储在本机,不会上传到任何服务器。', icon: Icons.lock_outline),
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

/// 接入方式切换卡:直连 Token ↔ Bot 授权。
class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode, required this.onSelect});

  final AuthMode mode;
  final ValueChanged<AuthMode> onSelect;

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
            Row(
              children: [
                Icon(Icons.swap_horiz, size: 20, color: scheme.primary),
                const SizedBox(width: 9),
                Text(
                  '接入方式',
                  style: context.texts.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
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
                    label: Text('Bot 授权'),
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
                  ? '直连模式:自带 NAI 令牌,直接连 NovelAI,扣自己账户 Anlas。'
                  : 'Bot 模式:后端用你的 Bot 账号身份生成,无需自备令牌。',
              style: context.texts.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标签补全来源切换卡:增强(后端)↔ Danbooru(直连英文)。
/// 非 bot 时增强段禁用,强制直连,呼应「未授权不走后端」。
class _CompletionCard extends StatelessWidget {
  const _CompletionCard({
    required this.source,
    required this.botMode,
    required this.onSelect,
  });

  final CompletionSource source;
  final bool botMode;
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
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
                const SizedBox(width: 9),
                Text(
                  '标签补全',
                  style: context.texts.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<CompletionSource>(
                segments: [
                  ButtonSegment(
                    value: CompletionSource.enhanced,
                    label: const Text('增强'),
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    enabled: botMode,
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
            const SizedBox(height: 10),
            Text(
              botMode
                  ? (source == CompletionSource.enhanced
                        ? '增强:走你的后端,英文补全 + 中文翻译(注音)+ 中文直接搜词。'
                        : '离线词库:内置约 14 万 Danbooru 标签(含中文),本地匹配、不联网。')
                  : '未授权 Bot,用内置离线词库(约 14 万标签,含中文),本地匹配、不联网。授权后可切到增强(实时 + 中文搜词)。',
              style: context.texts.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
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
                Icon(Icons.smart_toy_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 9),
                Text(
                  'Bot 授权',
                  style: context.texts.bodyLarge!.copyWith(
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
              Text(
                '尚未授权。授权后即可用后端(你的 Bot 账号身份)生成。',
                style: context.texts.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
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
            const SizedBox(height: 10),
            const InfoNote(
              '会话(等同后端令牌)加密存储在本机,7 天不活跃后失效。',
              icon: Icons.lock_outline,
            ),
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

/// 提示词预设管理入口:显示当前激活档,点进独立管理页。
class _VibeLibraryEntryCard extends ConsumerWidget {
  const _VibeLibraryEntryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final count = ref.watch(vibeLibraryProvider).value?.length;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(
          context,
        ).push(sharedAxisRoute(const VibeLibraryPage())),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Icon(Icons.palette_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Vibe 库',
                      style: context.texts.bodyLarge!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      count == null ? '加载中…' : '$count 条 · 导入 / 导出 / 预编码',
                      style: context.texts.bodySmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetEntryCard extends ConsumerWidget {
  const _PresetEntryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final active = ref.watch(promptPresetsProvider).value?.active;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(
          context,
        ).push(sharedAxisRoute(const PromptPresetManagePage())),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Icon(Icons.bookmark_outline, size: 20, color: scheme.primary),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '提示词预设',
                      style: context.texts.bodyLarge!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      active == null ? '加载中…' : '当前:${active.name}',
                      style: context.texts.bodySmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}
