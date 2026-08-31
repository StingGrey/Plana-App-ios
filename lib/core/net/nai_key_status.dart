import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'nai_client.dart';

/// 单把 Key 的账户状态(档位 / Anlas / V5 额度)—— 账号页每行下方那条读数。
///
/// 按**令牌**做 family 而不是按 Key 的 id:换令牌(手动重贴、JWT 续期)之后
/// 显示的必须是新账号的数,按 id 缓存会把旧账号的读数一直挂在那儿。
///
/// 不走 [NaiGate]:这是只读的 `/user/subscription`,排在生成后面的话开一次页面
/// 要等好几张图跑完才出数,而它并不占那条「同 Key 不许并发」的生成额度。
///
/// `autoDispose` —— 离开账号页就丢掉,下次进来重新拉。点数是会变的,
/// 缓存一份旧的比不显示更糟。
final naiKeyStatusProvider = FutureProvider.autoDispose
    .family<NaiSubscription, String>((ref, token) async {
      return ref.read(naiClientProvider).subscription(token);
    });
