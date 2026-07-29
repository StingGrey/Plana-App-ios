import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../net/nai_client.dart';
import 'secure_storage.dart';
import 'token_store.dart';

/// NAI 账号密码登录:密码在本机派生 access key(密码本身不出设备、不落盘),
/// 拿 key 换 30 天 JWT 走现有 token 管道。这是官网网页端同款零知识算法 ——
/// 服务器只见派生结果。参数(Blake2b-16 盐 / Argon2id 2轮·1953KB·并行1·64字节)
/// 由 test/core/auth 的 Python argon2-cffi 参考向量钉死,改动必先过测试。
///
/// `/user/*` 在 2026-07-04 迁到了 image 子域;旧 api.novelai.net 回
/// 400 "Please refresh NovelAI.net",别改回去。
const _userHost = 'https://image.novelai.net';

/// 派生 access key(纯计算,Argon2id 约几百毫秒,UI 侧用 [deriveNaiAccessKeyOffMain])。
///
/// pre_salt = 密码前 6 字符 + email + 固定域名串;salt = Blake2b-16(pre_salt);
/// key = base64url(Argon2id(password, salt)) 去 '=' 取前 64 字符。
Future<String> deriveNaiAccessKey(String email, String password) async {
  final prefix = password.length <= 6 ? password : password.substring(0, 6);
  final preSalt = '$prefix${email}novelai_data_access_key';
  final salt = await Blake2b(hashLengthInBytes: 16).hash(utf8.encode(preSalt));

  final argon = Argon2id(
    parallelism: 1,
    memory: 2000000 ~/ 1024, // 1953 KiB,NAI 官方就是这个不整的数
    iterations: 2,
    hashLength: 64,
  );
  final key = await argon.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt.bytes,
  );
  final encoded = base64Url.encode(await key.extractBytes()).replaceAll(
    '=',
    '',
  );
  return encoded.substring(0, 64);
}

Future<String> _deriveEntry(List<String> args) =>
    deriveNaiAccessKey(args[0], args[1]);

/// isolate 里派生,主线程不掉帧。
Future<String> deriveNaiAccessKeyOffMain(String email, String password) =>
    compute(_deriveEntry, [email, password]);

/// 拿 access key 换 JWT:POST /user/login {key} → accessToken。
/// 401 = key 不对,对用户而言就是邮箱或密码错了。
Future<String> naiLoginWithKey(String accessKey) async {
  final http.Response resp;
  try {
    resp = await http
        .post(
          Uri.parse('$_userHost/user/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'key': accessKey}),
        )
        .timeout(const Duration(seconds: 30));
  } catch (e) {
    throw NaiException('网络错误:$e');
  }
  if (resp.statusCode == 401) {
    throw NaiException('邮箱或密码错误', status: 401);
  }
  // 成功是 201 Created(创建会话),判 2xx 而不是 ==200(实测踩过)。
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw NaiException('登录失败(HTTP ${resp.statusCode})', status: resp.statusCode);
  }
  final data = jsonDecode(resp.body);
  final token = data is Map ? data['accessToken'] : null;
  if (token is! String || token.isEmpty) {
    throw NaiException('登录响应缺少 accessToken');
  }
  return token;
}

/// 登录要依次尝试的邮箱形态:小写 → 原始输入 → 首字母大写(去重保序)。
///
/// NAI 从未规范化过注册邮箱 —— 注册时输入什么大小写,盐里就是什么。
/// 官网登录页就是按这个顺序兜底的(源码 login chunk 逐字核对过),
/// 少任何一种都会出现「官网能登、App 报密码错误」。
List<String> naiEmailForms(String rawEmail) {
  final input = rawEmail.trim();
  final lower = input.toLowerCase();
  final capital = lower.isEmpty
      ? lower
      : lower[0].toUpperCase() + lower.substring(1);
  return <String>[
    lower,
    if (input != lower) input,
    if (capital != lower && capital != input) capital,
  ];
}

/// 完整登录:对每种邮箱形态派生 + 换 JWT,401 换下一形态,全败才算
/// 密码错误;非 401(网络/服务器问题)立刻上抛不空耗。
/// 返回成功的 (JWT, accessKey) —— accessKey 即续期凭证。
Future<(String, String)> naiCredentialLoginFlow(
  String rawEmail,
  String password,
) async {
  NaiException? denied;
  for (final email in naiEmailForms(rawEmail)) {
    final key = await deriveNaiAccessKeyOffMain(email, password);
    try {
      return (await naiLoginWithKey(key), key);
    } on NaiException catch (e) {
      if (e.status != 401) rethrow;
      denied = e;
    }
  }
  throw denied ?? NaiException('邮箱或密码错误', status: 401);
}

/// JWT 过期时刻(UTC);不是三段式 / 解不出 exp(如 pst- 令牌)返回 null。
DateTime? naiJwtExpiry(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final exp = payload is Map ? payload['exp'] : null;
    if (exp is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
  } catch (_) {
    return null;
  }
}

/// 账号密码登录留下的续期凭证(派生 access key,非密码)。
/// 存这个才能在 JWT 到期时静默换新;pst / 手贴 JWT 用户没有这份,也不需要。
///
/// 存储键刻意避开 token_store 的 `nai_access_token` —— 名字只差一个词,
/// 混用会互相覆盖。
const _accessKeyKey = 'nai_login_access_key';

final accessKeyProvider = AsyncNotifierProvider<AccessKeyNotifier, String?>(
  AccessKeyNotifier.new,
);

class AccessKeyNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    try {
      final v = await ref.read(secureStorageProvider).read(key: _accessKeyKey);
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String key) async {
    try {
      await ref.read(secureStorageProvider).write(key: _accessKeyKey, value: key);
      state = AsyncData(key);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> clear() async {
    try {
      await ref.read(secureStorageProvider).delete(key: _accessKeyKey);
    } catch (_) {}
    state = const AsyncData(null);
  }
}

/// 启动静默续期:主界面 `ref.watch` 一次即触发。当前 token 是 15 天内到期
/// (或已过期)的 JWT、且存有续期凭证时,重新换一枚新 JWT 落盘;其余情况
/// (pst 令牌 / 手贴 JWT 无凭证 / 还早)什么都不做。失败静默 —— 续期是
/// 锦上添花,下次启动再试,真 401 时 UI 自有失败态引导重登。
///
/// 15 天窗口 = 30 天寿命过半就换,用户哪怕半个月不开 App 也不会撞上过期。
final naiTokenAutoRefreshProvider = FutureProvider<void>((ref) async {
  try {
    final token = await ref.read(tokenProvider.future);
    if (token == null) return;
    final expiry = naiJwtExpiry(token);
    if (expiry == null) return; // pst- 令牌不过期,无需续
    if (expiry.difference(DateTime.now().toUtc()) > const Duration(days: 15)) {
      return;
    }
    final accessKey = await ref.read(accessKeyProvider.future);
    if (accessKey == null) return; // 手贴 JWT,没有续期凭证,只能到期重贴
    final fresh = await naiLoginWithKey(accessKey);
    await ref.read(tokenProvider.notifier).save(fresh);
  } catch (_) {
    // 静默失败,见上。
  }
});
