import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 液态玻璃风格 UI 基建。
///
/// 全项目弹窗统一走 [showGlassDialog]：居中弹出（不用底部弹出）、
/// 背后内容高斯模糊（BackdropFilter）、半透明面板 + 亮边描边，
/// 即「液态玻璃」质感。任何新的弹窗/选项都不要再写裸 showDialog
/// 或 showModalBottomSheet。

/// 居中弹出液态玻璃对话框。
///
/// [builder] 返回的内容会被包进玻璃面板；面板本身不提供标题/按钮，
/// 由调用方用 AlertDialog 或自定义 Column 组装。
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
      // 去掉 Dialog 默认的内边距与最小尺寸约束，
      // 由玻璃面板自己控制（否则窄弹窗两侧有大片透明区）。
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: glassPanel(
        context,
        builder(ctx),
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
          // 深浅模式各给一层半透明底：玻璃感的关键是透出不模糊的上层内容
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

/// 居中选项列表（替代 showModalBottomSheet 的标准形态）。
///
/// [groups] 为选项分组：组间有分隔线。返回选中项的 value。
Future<T?> showGlassOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<List<({T value, String label, String? desc})>> groups,
}) {
  return showGlassDialog<T>(
    context: context,
    builder: (ctx) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            for (var g = 0; g < groups.length; g++) ...[
              if (g > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Divider(
                      height: 1, color: onSurface(context, 0.08)),
                ),
              for (final opt in groups[g])
                ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  title: Text(opt.label,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w500)),
                  subtitle: opt.desc == null
                      ? null
                      : Text(opt.desc!,
                          style: TextStyle(
                              fontSize: 12,
                              color: onSurface(context, 0.45))),
                  onTap: () => Navigator.pop(ctx, opt.value),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}
