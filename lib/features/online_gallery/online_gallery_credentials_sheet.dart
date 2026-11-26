import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/haptics.dart';
import '../generate/widgets/common.dart' show hintSnack;
import 'online_gallery_credentials.dart';
import 'online_gallery_service.dart';

/// 在线画廊「API Key」面板:各来源的凭据一页填完,保存后按新凭据重拉当前列表。
Future<void> showOnlineGalleryCredentialsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const _CredentialsSheet(),
    );

class _CredentialsSheet extends ConsumerStatefulWidget {
  const _CredentialsSheet();

  @override
  ConsumerState<_CredentialsSheet> createState() => _CredentialsSheetState();
}

class _CredentialsSheetState extends ConsumerState<_CredentialsSheet> {
  final _danLogin = TextEditingController();
  final _danKey = TextEditingController();
  final _gelUser = TextEditingController();
  final _gelKey = TextEditingController();
  final _jinaKey = TextEditingController();

  /// 各密钥格各自的显隐。
  final _shown = <TextEditingController>{};
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fill();
  }

  Future<void> _fill() async {
    final c = await ref.read(onlineGalleryCredentialsProvider.future);
    if (!mounted) return;
    setState(() {
      _danLogin.text = c.danbooruLogin;
      _danKey.text = c.danbooruApiKey;
      _gelUser.text = c.gelbooruUserId;
      _gelKey.text = c.gelbooruApiKey;
      _jinaKey.text = c.jinaApiKey;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    for (final c in [_danLogin, _danKey, _gelUser, _gelKey, _jinaKey]) {
      c.dispose();
    }
    super.dispose();
  }

  OnlineGalleryCredentials get _draft => OnlineGalleryCredentials(
    danbooruLogin: _danLogin.text.trim(),
    danbooruApiKey: _danKey.text.trim(),
    gelbooruUserId: _gelUser.text.trim(),
    gelbooruApiKey: _gelKey.text.trim(),
    jinaApiKey: _jinaKey.text.trim(),
  );

  /// 只填了一半的来源(用户名有了没 Key 之类),保存前拦一下。
  String? get _incomplete {
    final d = _draft;
    if ((d.danbooruLogin.isEmpty) != (d.danbooruApiKey.isEmpty)) {
      return 'Danbooru 需要用户名和 API Key 都填上';
    }
    if ((d.gelbooruUserId.isEmpty) != (d.gelbooruApiKey.isEmpty)) {
      return 'Gelbooru 需要 User ID 和 API Key 都填上';
    }
    if (d.gelbooruUserId.isNotEmpty &&
        !RegExp(r'^\d+$').hasMatch(d.gelbooruUserId)) {
      return 'Gelbooru 的 User ID 是一串数字';
    }
    return null;
  }

  /// Gelbooru 账户页给的是一整串 `&api_key=…&user_id=…`,贴进任一格就拆开。
  void _maybeSplitGelbooru(String text) {
    final parsed = parseGelbooruCredentialString(text);
    if (parsed == null) return;
    setState(() {
      _gelUser.text = parsed.userId;
      _gelKey.text = parsed.apiKey;
    });
  }

  Future<void> _save(OnlineGalleryCredentials next) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final before = ref.read(onlineGalleryCredentialsProvider).value;
    setState(() => _busy = true);
    await ref.read(onlineGalleryCredentialsProvider.notifier).save(next);
    if (!mounted) return;
    if (before != next) {
      ref.read(onlineGalleryProvider.notifier).reloadForCredentials();
    }
    Haptics.selection();
    // 提示挂在根 Overlay 上,先弹再关面板也留得住
    hintSnack(
      context,
      next.isEmpty ? '已清除,在线画廊改为匿名访问' : '已保存 API Key',
      icon: Icons.key_outlined,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final error = _loaded ? _incomplete : null;
    return Padding(
      // 键盘弹起时把内容顶上去
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'API Key',
              style: context.texts.titleMedium!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '都可以不填,不填就匿名访问。只存在本机加密存储里,也只发给对应的站点。',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
            const SizedBox(height: 14),
            _section(
              title: 'Danbooru / Safebooru',
              done: _draft.hasDanbooru,
              hint:
                  '登录 danbooru.donmai.us → 我的账户 → API Key 里新建一把,两边共用这一把'
                  '(Safebooru 就是 Danbooru 只看全年龄的那一面)。'
                  '填了按账号权限访问:搜索可用的标签数、能看的内容随账号等级,限流也更宽。',
              children: [
                _field(_danLogin, '用户名'),
                const SizedBox(height: 8),
                _field(_danKey, 'API Key', secret: true),
              ],
            ),
            _section(
              title: 'Gelbooru',
              done: _draft.hasGelbooru,
              hint:
                  '登录 gelbooru.com → My Account → Options → API Access Credentials,'
                  '整串复制粘进任一格会自动拆开。填了改走官方接口,能拿到原图、尺寸和发布日期。',
              children: [
                _field(
                  _gelUser,
                  'User ID',
                  keyboard: TextInputType.text,
                  onChanged: _maybeSplitGelbooru,
                ),
                const SizedBox(height: 8),
                _field(
                  _gelKey,
                  'API Key',
                  secret: true,
                  onChanged: _maybeSplitGelbooru,
                ),
              ],
            ),
            _section(
              title: 'AI TAG',
              done: _draft.hasJina,
              hint:
                  'AI TAG 本身没有开放 API Key。它的接口被 Cloudflare 拦下时会经 Jina Reader 中转,'
                  '匿名额度很低、刷快了会报 429;在 jina.ai 免费申请一把 Key 填这里就能提额。',
              children: [_field(_jinaKey, 'Jina Reader API Key', secret: true)],
            ),
            if (error != null) ...[
              Text(
                error,
                style: context.texts.labelSmall!.copyWith(color: scheme.error),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                TextButton(
                  onPressed: !_loaded || _busy
                      ? null
                      : () => _save(const OnlineGalleryCredentials()),
                  child: const Text('全部清除'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: !_loaded || _busy || error != null
                      ? null
                      : () => _save(_draft),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(120, 44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _section({
    required String title,
    required bool done,
    required String hint,
    required List<Widget> children,
  }) {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                title,
                style: context.texts.titleSmall!.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              if (done)
                Icon(Icons.check_circle, size: 16, color: scheme.primary),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: context.texts.labelSmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String hint, {
    bool secret = false,
    TextInputType? keyboard,
    ValueChanged<String>? onChanged,
  }) {
    final scheme = context.scheme;
    final hidden = secret && !_shown.contains(c);
    return TextField(
      controller: c,
      enabled: _loaded && !_busy,
      obscureText: hidden,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: secret ? TextInputType.visiblePassword : keyboard,
      onChanged: (v) {
        onChanged?.call(v);
        setState(() {});
      },
      style: mono(context, size: 13),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        hintText: hint,
        hintStyle: TextStyle(color: scheme.outline),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        suffixIcon: secret
            ? IconButton(
                tooltip: hidden ? '显示' : '隐藏',
                onPressed: () =>
                    setState(() => hidden ? _shown.add(c) : _shown.remove(c)),
                icon: Icon(
                  hidden ? Icons.visibility : Icons.visibility_off,
                  size: 20,
                ),
                color: scheme.onSurfaceVariant,
              )
            : null,
      ),
    );
  }
}
