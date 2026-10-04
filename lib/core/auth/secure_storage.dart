import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 全局唯一的加密存储**配置**(令牌 / bot 会话 / 后端地址 等设置共用)。
///
/// **任何读写点都必须用这个常量或下面的 provider,不要自己 `new` 一份。**
/// 现在各处配置相同,看不出差别;但一旦给它加上 `AndroidOptions`
/// (`resetOnError: false` 等,见 S1A-02),自建的那份会是**唯一没跟上的**,
/// 而且编译器和 lint 都不会提醒 —— 表现为「某一项设置莫名其妙被清空」。
///
/// 直接暴露常量是给启动阶段用的(ProviderScope 建立之前拿不到 ref):
/// 设置迁移(`PrefsStore`)和凭据出口的判定(`CredentialStore`)。
const kSecureStorage = FlutterSecureStorage();

/// ProviderScope 内的凭据读写统一走这里。`main()` 把它换成 `CredentialStore`:
/// 平时就是上面这份,这台机留不住加密存储时改存文件。测试不覆盖时就是
/// [kSecureStorage]。
final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => kSecureStorage,
);
