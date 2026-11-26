import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../editor/data/suggestions.dart' show translationOf;
import '../editor/data/tag_translation_service.dart';
import 'online_gallery_models.dart';

/// 查某个标签的译名 / 它是否还在等译名。
typedef GalleryTagTrans = ({
  String? Function(String tag) of,
  bool Function(String tag) pending,
});

/// 画师名不是词库里的标签,反查只会串味(同 `transOf(Suggestion)` 跳过画师)。
bool galleryTagTranslatable(OnlineGalleryTagCategory category) =>
    category != OnlineGalleryTagCategory.artist;

/// 在线画廊标签的中文译名,与编辑器、灵感页芯片同一条链路:先查共享缓存 /
/// 离线词库([translationOf]),缺的交给 [TagTranslationService] 攒批联网补,
/// 到货就刷新这一片。
///
/// 选词弹层也用它,而弹层有时单独挂(测试里不带 ProviderScope):找不到
/// ProviderScope 时只用离线那一层,不联网、不报错。
class GalleryTagTranslations extends StatefulWidget {
  const GalleryTagTranslations({
    super.key,
    required this.tags,
    required this.builder,
  });

  /// 要译名的标签(画师已排除,见 [galleryTagTranslatable])。
  final List<String> tags;
  final Widget Function(BuildContext context, GalleryTagTrans trans) builder;

  @override
  State<GalleryTagTranslations> createState() => _GalleryTagTranslationsState();
}

class _GalleryTagTranslationsState extends State<GalleryTagTranslations> {
  ProviderSubscription<TagTranslationService>? _sub;
  TagTranslationService? _svc;
  bool _subscribed = false;

  void _onTrans() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_subscribed) return;
    _subscribed = true;
    final ProviderContainer container;
    try {
      container = ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return;
    }
    // 服务随后端基址换代:换了就把监听挪过去,缺的补问一遍
    _sub = container.listen<TagTranslationService>(
      tagTranslationServiceProvider,
      (_, next) => _attach(next),
      fireImmediately: true,
    );
  }

  void _attach(TagTranslationService svc) {
    if (identical(svc, _svc)) return;
    final first = _svc == null;
    _svc?.removeListener(_onTrans);
    _svc = svc..addListener(_onTrans);
    svc.request(widget.tags);
    if (!first) _onTrans(); // 首次在 didChangeDependencies 里,build 紧跟着
  }

  @override
  void didUpdateWidget(covariant GalleryTagTranslations old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.tags, widget.tags)) _svc?.request(widget.tags);
  }

  @override
  void dispose() {
    _sub?.close();
    // removeListener 允许晚于服务本体 dispose(provider 换代时先死的是它)
    _svc?.removeListener(_onTrans);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = _svc;
    return widget.builder(context, (
      of: translationOf,
      pending: svc == null ? (_) => false : svc.isPending,
    ));
  }
}

/// 详情页的一颗标签:英文名 + 下面一行小字译名,配色跟分类走。
///
/// 可翻译的标签译文行**恒占位**(编辑器 / 灵感页芯片同款):异步到货或答不出
/// 都不跳版;画师不占这一行。
class GalleryTagChip extends StatelessWidget {
  const GalleryTagChip({
    super.key,
    required this.tag,
    required this.color,
    this.trans,
    this.pending = false,
    this.reserveTrans = true,
    this.onTap,
    this.onLongPress,
  });

  final String tag;
  final Color color;
  final String? trans;
  final bool pending;
  final bool reserveTrans;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final trans = this.trans;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Material(
        color: Color.alphaBlend(
          color.withValues(alpha: .07),
          scheme.surfaceContainerLow,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
          side: BorderSide(color: color.withValues(alpha: .28)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 5, 9, 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tag.replaceAll('_', ' '),
                  style: context.texts.labelLarge!.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
                if (reserveTrans || trans != null)
                  SizedBox(
                    height: 15,
                    child: trans != null
                        ? Text(
                            trans,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              height: 1.4,
                              color: scheme.onSurfaceVariant,
                            ),
                          )
                        : pending
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              width: 26,
                              height: 5,
                              decoration: BoxDecoration(
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: .18,
                                ),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---- 搜索框联想 ----

/// 搜索框里光标所在的那个词:前半段、`-` / `~` 前缀、词本身、后半段。
typedef GalleryQueryWord = ({
  String head,
  String prefix,
  String term,
  String tail,
});

/// 取光标所在的词(空白分隔);光标落在空白上、或只有前缀时回 null。
GalleryQueryWord? galleryQueryWordAt(TextEditingValue value) {
  final text = value.text;
  final sel = value.selection;
  final cursor = (sel.isValid ? sel.baseOffset : text.length).clamp(
    0,
    text.length,
  );
  bool space(int i) => text[i].trim().isEmpty;
  var start = cursor;
  while (start > 0 && !space(start - 1)) {
    start--;
  }
  var end = cursor;
  while (end < text.length && !space(end)) {
    end++;
  }
  final word = text.substring(start, end);
  final prefix = RegExp(r'^[-~]*').firstMatch(word)![0]!;
  final term = word.substring(prefix.length);
  if (term.isEmpty) return null;
  return (
    head: text.substring(0, start),
    prefix: prefix,
    term: term,
    tail: text.substring(end),
  );
}

/// 用 [value] 换掉 [word] 那个词(前缀保留),后面补一个空格接着输入。
String galleryQueryReplace(GalleryQueryWord word, String value) =>
    '${word.head}${word.prefix}$value ${word.tail.trimLeft()}';

/// 值不值得去问联想:两个字符起;中日文一个字就够(「初」能联想到初音)。
bool galleryWorthSuggesting(String term) =>
    term.runes.length >= 2 || RegExp(r'[぀-ヿ㐀-鿿]').hasMatch(term);

/// 帖子数缩写:395 / 5.9k / 62k / 2.2M(Danbooru 网页同款)。
String formatTagPostCount(int n) {
  String trim(String s) => s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  if (n >= 1000000) {
    return '${trim((n / 1000000).toStringAsFixed(n >= 10000000 ? 0 : 1))}M';
  }
  if (n >= 1000) {
    return '${trim((n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1))}k';
  }
  return '$n';
}

/// 联想下拉里的一行:匹配到的那段加粗,颜色跟类目,右边帖子数,下面一行中文。
class GallerySuggestionTile extends StatelessWidget {
  const GallerySuggestionTile({
    super.key,
    required this.label,
    required this.term,
    required this.color,
    required this.postCount,
    this.antecedent,
    this.translation,
    this.highlighted = false,
    required this.onTap,
  });

  final String label;
  final String term;
  final Color color;
  final int postCount;
  final String? antecedent;
  final String? translation;
  final bool highlighted;
  final VoidCallback onTap;

  /// [text] 里第一处 [term](不分大小写,下划线当空格)加粗。
  static List<TextSpan> _bold(String text, String term, TextStyle strong) {
    final t = term.replaceAll('_', ' ').toLowerCase();
    final i = t.isEmpty ? -1 : text.toLowerCase().indexOf(t);
    if (i < 0) return [TextSpan(text: text)];
    return [
      TextSpan(text: text.substring(0, i)),
      TextSpan(text: text.substring(i, i + t.length), style: strong),
      TextSpan(text: text.substring(i + t.length)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final strong = const TextStyle(fontWeight: FontWeight.w800);
    final antecedent = this.antecedent;
    final translation = this.translation;
    return Material(
      color: highlighted
          ? scheme.onSurface.withValues(alpha: .06)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        style: context.texts.bodyMedium!.copyWith(
                          color: color,
                          fontWeight: FontWeight.w500,
                        ),
                        children: [
                          if (antecedent != null) ...[
                            TextSpan(
                              children: _bold(
                                antecedent.replaceAll('_', ' '),
                                term,
                                strong,
                              ),
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                            TextSpan(
                              text: '  →  ',
                              style: TextStyle(color: scheme.outline),
                            ),
                            TextSpan(text: label),
                          ] else
                            ..._bold(label, term, strong),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (translation != null && translation.isNotEmpty)
                      Text(
                        translation,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.labelSmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (postCount > 0) ...[
                const SizedBox(width: 12),
                Text(
                  formatTagPostCount(postCount),
                  style: context.texts.labelMedium!.copyWith(
                    color: scheme.outline,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
