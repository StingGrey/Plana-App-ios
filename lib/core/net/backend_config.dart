import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Plana 后端基址。形如 `https://nai.sora214.top`,末尾无斜杠;
/// `/api` 前缀由 client 补,WS 由 `^http`→`ws` 推出(`https`→`wss`)。
const kDefaultBackendBase = 'https://nai.sora214.top';

/// 固定用内置后端,不读本地存的旧地址。
final backendBaseProvider = AsyncNotifierProvider<BackendBaseNotifier, String>(
  BackendBaseNotifier.new,
);

class BackendBaseNotifier extends AsyncNotifier<String> {
  @override
  FutureOr<String> build() => kDefaultBackendBase;
}
