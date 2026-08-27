import 'package:flutter/material.dart';

import '../generate/widgets/common.dart' show InfoNote;
import 'bot_auth_panel.dart';

/// Bot 授权页(「账号与接入」入口):面板 + 说明,授权成功即返回。
/// 流程本体在 [BotAuthPanel],与首启欢迎流程共用。
class BotAuthPage extends StatelessWidget {
  const BotAuthPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bot 授权')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          BotAuthPanel(onAuthorized: () => Navigator.of(context).maybePop()),
          const SizedBox(height: 16),
          const InfoNote('取到码后点「复制指令」,在 QQ/Discord 发给 Plana Bot,本页自动完成授权。'),
        ],
      ),
    );
  }
}
