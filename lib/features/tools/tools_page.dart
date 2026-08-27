import 'package:flutter/material.dart';

import 'metadata_tool_page.dart';
import 'weight_convert_page.dart';

/// 工具箱(对齐 web):权重转换 / 图片元数据 两个页签,
/// IndexedStack 保活,切页签不丢已输入内容与已选图。
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('工具箱')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 0,
                    label: Text('权重转换'),
                    icon: Icon(Icons.swap_horiz, size: 17),
                  ),
                  ButtonSegment(
                    value: 1,
                    label: Text('图片元数据'),
                    icon: Icon(Icons.document_scanner_outlined, size: 17),
                  ),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
                showSelectedIcon: false,
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: const [WeightConvertView(), MetadataToolView()],
            ),
          ),
        ],
      ),
    );
  }
}
