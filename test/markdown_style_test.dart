import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

/// Markdown 渲染回归测试（v0.2.5）。
///
/// v0.2.1~v0.2.4 白屏根因：自定义 MarkdownStyleSheet 用裸构造，导致
/// listBulletPadding / checkbox / listIndent 为 null，而 flutter_markdown
/// 内部对它们非空断言（listBulletPadding! / checkbox! / listIndent!）——
/// 消息里出现列表即抛 "Null check operator used on a null value"。
/// 本测试用与线上一致的「fromTheme 基底」样式表渲染各类消息片段，
/// 任何 null 断言都会让 testWidgets 抛出并让 CI 变红。
void main() {
  final samples = <String>[
    '普通段落，没有任何格式。',
    '- 项目一\n- 项目二\n- 项目三',
    '1. 有序一\n2. 有序二',
    '- [ ] 待办事项\n- [x] 已完成事项',
    '> 这是引用块内容',
    '```json\n{"name": "张伟", "years": 5}\n```',
    '行内 `code` 与 **加粗** 与 *斜体* 与 [链接](https://example.com)',
    '# 一级标题\n\n## 二级标题\n\n### 三级标题',
    '混合内容：\n\n- 列表项含 `代码`\n- **加粗** 列表项\n\n> 引用里也有列表：\n> - 引用内列表',
  ];

  for (final s in samples) {
    testWidgets('Markdown 渲染不抛异常: ${s.split('\n').first}', (tester) async {
      // 与 chat_screen._mdStyleSheet 同构：fromTheme 基底 + 覆盖字段。
      final sheet =
          MarkdownStyleSheet.fromTheme(ThemeData(useMaterial3: true)).copyWith(
        p: const TextStyle(fontSize: 15.5, height: 1.6),
        codeblockDecoration: const BoxDecoration(),
        codeblockPadding: EdgeInsets.zero,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MarkdownBody(data: s, styleSheet: sheet)),
      ));
      expect(tester.takeException(), isNull);
    });
  }
}
