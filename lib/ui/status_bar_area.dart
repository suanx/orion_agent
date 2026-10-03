import 'package:flutter/material.dart';

import '../theme.dart';

/// 顶栏容器：自动把状态栏那条区域也涂成页面底色。
///
/// 为什么需要它：edge-to-edge（Android 15 起强制）下内容延伸到状态栏下方，
/// 而 [SafeArea] **只给子节点加 padding、自身不画背景**——状态栏那一条
/// 没人涂色就会透出窗口底色，看起来是「黑边」。
///
/// 为什么做成公共组件而不是各页面自己包：这是一条**全局约束**，四个页面
/// 都得满足。逐页包Container 必然会漏（这次就是 tasks / profile / skills
/// 三个页面漏了，只有 chat_screen 改了），以后新增页面又要记得包一次。
/// 统一由它提供，新页面只要用它就不会漏。
///
/// 独立成文件而不放在 home_shell.dart：HomeShell 导入了 tasks / profile /
/// skills 三个页面，组件若定义在 home_shell 里，那三个页面再导入它就形成
/// 循环依赖（Dart 允许但会让人困扰，且 analyze 会告警）。
///
/// 用法：`StatusBarArea(child: SafeArea(bottom: false, child: 顶栏内容))`
class StatusBarArea extends StatelessWidget {
  const StatusBarArea({super.key, required this.child, this.color});

  final Widget child;

  /// 顶栏背景色。默认取页面底色（[scaffoldBg]），与 Scaffold 背景一致，
  /// 所以状态栏、顶栏、页面三者是同一个颜色，看不出接缝。
  ///
  /// 需要与页面底色不同时才传（如对话页想用更深的纯色顶栏）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      // 用 [scaffoldBg]（= scaffoldBackgroundColor，页面底色）而不是
      // surface（卡片色）：后者更亮，涂在状态栏上会出现一条色差带。
      color: color ?? scaffoldBg(context),
      child: child,
    );
  }
}
