import 'dart:ui';

import 'package:flutter/material.dart';

/// 液态玻璃风格 UI 基建。
///
/// 全项目弹窗统一走 [showGlassDialog]：居中弹出（不用底部弹出）、
/// 背后内容高斯模糊（BackdropFilter）、半透明面板 + 亮边描边，
/// 即「液态玻璃」质感。任何新的弹窗/选项都不要再写裸 showDialog
/// 或 showModalBottomSheet。

/// 居中弹出液态玻璃对话框。
///
/// [builder] 通常返回 AlertDialog（也可以是任意内容）。实现要点：
/// - 外层 [Dialog] 背景透明 + insetPadding 归零，宽度由内层内容决定；
/// - [glassPanel] 提供模糊 + 半透明 + 亮边；
/// - 用 Theme 覆写 dialogTheme（背景透明、无阴影），这样 builder 里
///   **不指定 backgroundColor 的 AlertDialog 也是透明的**——机械替换
///   进来的旧弹窗不用逐个改颜色，玻璃面板都能透出来。
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.black26,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      // 归零：面板宽度交给内层 AlertDialog 的 insetPadding 决定，
      // 否则两层 padding 叠加会把窄屏的面板挤得过窄。
      insetPadding: EdgeInsets.zero,
      child: glassPanel(
        context,
        Theme(
          data: Theme.of(context).copyWith(
            dialogTheme: const DialogThemeData(
              backgroundColor: Colors.transparent,
              elevation: 0,
            ),
          ),
          child: builder(ctx),
        ),
        borderRadius: 24,
      ),
    ),
  );
}

/// 把任意内容包进液态玻璃面板（模糊 + 半透明 + 亮边）。
///
/// 常用于：对话框内容、居中选项列表。页面卡片不必用它——
/// 卡片下面没有可透出的内容，模糊没有意义。
Widget glassPanel(
  BuildContext context,
  Widget child, {
  double borderRadius = 20,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return ClipRRect(
    borderRadius: BorderRadius.circular(borderRadius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
      child: Container(
        decoration: BoxDecoration(
          // 深浅模式各给一层半透明底：玻璃感的关键是透出被模糊的内容
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.white.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.65),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    ),
  );
}
