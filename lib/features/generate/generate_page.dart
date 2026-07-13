import 'package:flutter/material.dart';

import 'widgets/bottom_action_bar.dart';
import 'widgets/char_ref_card.dart';
import 'widgets/character_card.dart';
import 'widgets/img2img_card.dart';
import 'widgets/prompt_card.dart';
import 'widgets/top_bar.dart';
import 'widgets/vibe_card.dart';

/// 创作页:顶栏 + 折叠卡堆叠(滚动)+ 吸底操作栏
class GeneratePage extends StatelessWidget {
  const GeneratePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const GenerateTopBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
            children: const [
              PromptCard(),
              SizedBox(height: 9),
              CharacterCard(),
              SizedBox(height: 9),
              VibeCard(),
              SizedBox(height: 9),
              CharRefCard(),
              SizedBox(height: 9),
              Img2ImgCard(),
            ],
          ),
        ),
        const BottomActionBar(),
      ],
    );
  }
}
