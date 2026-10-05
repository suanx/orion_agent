import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 底栏键盘显隐动画回归测试（v0.2.6）。
///
/// v0.2.2~v0.2.5 崩溃根因：底栏用 AnimatedContainer(clipBehavior: Clip.hardEdge)
/// 且没有 decoration——Container.build 对「clip ≠ none 且 decoration == null」
/// 在 release 下解引用 decoration!（framework container.dart:413），
/// 抛 "Null check operator used on a null value"，首帧 mount 即崩（正式包才崩，
/// debug 里只是一条 assert，非常隐蔽）。
void main() {
  testWidgets('底栏 AnimatedSize 显隐（正确写法）不抛异常', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: const SizedBox(height: 100),
        bottomNavigationBar: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: const SizedBox(width: double.infinity),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);

    // 切到展开态再 pump 动画收尾
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: const SizedBox(height: 100),
        bottomNavigationBar: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: const SizedBox(width: double.infinity, height: 56),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('反例留档：clip 且无 decoration 的 Container 会触发断言', (tester) async {
    // 故意保留当年的错误写法：debug 测试环境下 assert(decoration != null)
    // 触发，被测试框架捕获。若未来 Flutter 移除了该断言，此用例会失败，
    // 提醒我们更新 home_shell 里的历史注释。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(height: 100),
        bottomNavigationBar: SizedBox(
          height: 56,
          child: Center(
            child: SizedBox(
              width: 120,
              height: 40,
              child: _CrashyClipContainer(),
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNotNull);
  });
}

/// 历史错误写法的最小复刻（仅测试用）。
class _CrashyClipContainer extends StatelessWidget {
  const _CrashyClipContainer();

  @override
  Widget build(BuildContext context) {
    // ignore: prefer_const_constructors, deprecated_member_use
    return Container(clipBehavior: Clip.hardEdge, child: const ColoredBox(color: Color(0xFFEEEEEE)));
  }
}
