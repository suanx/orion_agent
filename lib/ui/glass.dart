import 'dart:ui';

import 'package:flutter/material.dart';

/// 液态玻璃风格 UI 基建。
///
/// 两类弹出口径（全项目统一，不要再写裸 showDialog / showModalBottomSheet）：
/// - [showGlassDialog]：**紧凑居中**玻璃对话框（其他所有页面）；
/// - [showGlassAnchoredMenu]：**锚定在图标上方**的浮层菜单（对话页的
///   状态条 / 输入栏图标，参考同类产品的锚定交互）。

/// 紧凑居中的液态玻璃对话框。
///
/// 紧凑的含义（用户明确要求：其他页面弹窗不要全屏，只在屏幕中心显示）：
/// - 外层 [Dialog] 用横向 44 / 纵向 28 的 inset——面板距屏幕边缘留白，
///   内容再宽也不会铺满屏；
/// - 整体限宽 400，长表单（模型编辑等）也是一块居中卡片而不是整页。
/// - [glassPanel] 提供模糊 + 半透明 + 亮边；Theme 覆写 dialogTheme
///   （背景透明、无阴影），机械替换进来的 AlertDialog 无需改色。
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
      insetPadding: const EdgeInsets.symmetric(horizontal: 44, vertical: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: glassPanel(
          context,
          Theme(
            data: Theme.of(context).copyWith(
              dialogTheme: const DialogThemeData(
                backgroundColor: Colors.transparent,
                elevation: 0,
              ),
            ),
            // 透明 Material：builder 里可能是裸表单（TextField/InkWell
            // 都需要 Material 祖先），原来由 AlertDialog/Dialog 提供，
            // 紧凑化后不强制 builder 返回它们，这里统一兜底。
            child: Material(
              type: MaterialType.transparency,
              child: builder(ctx),
            ),
          ),
          borderRadius: 24,
        ),
      ),
    ),
  );
}

/// 锚定浮层的选项条目。
class GlassMenuOption<T> {
  const GlassMenuOption({
    required this.value,
    required this.title,
    this.subtitle,
    this.icon,
    this.checked = false,
    this.trailingLabel,
  });

  final T value;
  final String title;

  /// 副标题（灰字说明，如权限档位的用途）。
  final String? subtitle;

  /// 左侧图标（可省）。
  final IconData? icon;

  /// 当前选中项右侧打勾。
  final bool checked;

  /// 右侧灰字值（如「模型默认」），与 checked 互斥使用。
  final String? trailingLabel;
}

/// 在 [anchor]（图标/按钮的 BuildContext）**正上方**弹出玻璃菜单。
///
/// 参考同类产品的交互：点击状态条/输入栏图标，选项浮层贴着图标上沿
/// 展开，点浮层外任意处关闭。水平方向以图标中心对齐、两侧夹紧不出屏；
/// 图标太靠上放不下时自动改到下方。
///
/// 拿不到锚点位置（极端时序）时退化为紧凑居中弹窗。
Future<T?> showGlassAnchoredMenu<T>({
  required BuildContext context,
  required BuildContext anchor,
  required List<GlassMenuOption<T>> options,
  double width = 272,
}) {
  return _showAnchoredPanel<T>(
    context: context,
    anchor: anchor,
    width: width,
    builder: (routeCtx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final o in options)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => Navigator.of(routeCtx).pop(o.value),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  if (o.icon != null) ...[
                    Icon(o.icon, size: 20, color: onPanelText(routeCtx, 0.75)),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(o.title,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: onPanelText(routeCtx, 0.92))),
                        if (o.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(o.subtitle!,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: onPanelText(routeCtx, 0.45))),
                        ],
                      ],
                    ),
                  ),
                  if (o.checked)
                    Icon(Icons.check_rounded,
                        size: 20, color: onPanelText(routeCtx, 0.85))
                  else if (o.trailingLabel != null)
                    Text(o.trailingLabel!,
                        style: TextStyle(
                            fontSize: 13,
                            color: onPanelText(routeCtx, 0.45))),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

/// 在 [anchor] 正上方弹出任意内容的锚定面板（如上下文用量明细）。
Future<T?> showGlassAnchoredPanel<T>({
  required BuildContext context,
  required BuildContext anchor,
  required WidgetBuilder builder,
  double width = 300,
}) {
  return _showAnchoredPanel<T>(
    context: context,
    anchor: anchor,
    width: width,
    builder: builder,
  );
}

Future<T?> _showAnchoredPanel<T>({
  required BuildContext context,
  required BuildContext anchor,
  required double width,
  required WidgetBuilder builder,
}) {
  // 锚点在调用时必然已完成布局（onTap 触发于 build 之后），
  // 但防御一下：拿不到就退化为居中弹窗，功能不丢。
  final Object? ro = anchor.findRenderObject();
  if (ro is! RenderBox || !ro.attached || !ro.hasSize) {
    return showGlassDialog<T>(context: context, builder: builder);
  }
  final Object? overlayRo =
      Overlay.of(context, rootOverlay: true).context.findRenderObject();
  if (overlayRo is! RenderBox) {
    return showGlassDialog<T>(context: context, builder: builder);
  }
  final anchorTopLeft =
      ro.localToGlobal(Offset.zero, ancestor: overlayRo);
  final rect = anchorTopLeft & ro.size;

  return Navigator.of(context, rootNavigator: true).push(
    _AnchoredGlassRoute<T>(
      anchorRect: rect,
      width: width,
      builder: builder,
    ),
  );
}

class _AnchoredGlassRoute<T> extends PopupRoute<T> {
  _AnchoredGlassRoute({
    required this.anchorRect,
    required this.width,
    required this.builder,
  });

  final Rect anchorRect;
  final double width;
  final WidgetBuilder builder;

  @override
  Color? get barrierColor => Colors.black26;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭浮层';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return LayoutBuilder(builder: (ctx, cons) {
      final screenW = cons.maxWidth;
      final screenH = cons.maxHeight;

      // 水平：以锚点中心对齐，两侧夹紧不出屏
      final maxLeft = (screenW - width - 12).clamp(12.0, double.infinity);
      var left = (anchorRect.center.dx - width / 2).clamp(12.0, maxLeft);

      // 垂直：默认面板底边贴在锚点上方 10px；
      // 锚点本身在屏幕上半部（上方放不下菜单）时改到锚点下方。
      final bool above = anchorRect.center.dy >= screenH * 0.35;
      final double top = above
          ? 0
          : (anchorRect.bottom + 10).clamp(0.0, screenH - 120);
      final double? bottom =
          above ? (screenH - anchorRect.top + 10) : null;

      return Stack(
        children: [
          // 点浮层外任意处关闭（barrier 由 PopupRoute 提供，这里补齐
          // Stack 空隙区域的点击）
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ),
          Positioned(
            left: left,
            top: above ? null : top,
            bottom: above ? bottom : null,
            width: width,
            child: Theme(
              data: Theme.of(ctx).copyWith(
                dialogTheme: const DialogThemeData(
                    backgroundColor: Colors.transparent, elevation: 0),
              ),
              child: glassPanel(
                ctx,
                Material(
                  type: MaterialType.transparency,
                  child: builder(ctx),
                ),
                borderRadius: 20,
              ),
            ),
          ),
        ],
      );
    });
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // 轻微上浮 + 淡入，与「从图标上方展开」的方向一致
    final curved =
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// 把任意内容包进液态玻璃面板（模糊 + 半透明 + 亮边）。
///
/// 常用于：对话框内容、锚定浮层。页面卡片不必用它——
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

/// 玻璃面板上的文字颜色（深浅模式下都可读）。
Color onPanelText(BuildContext context, double opacity) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return (isDark ? Colors.white : const Color(0xFF1A1C1E))
      .withValues(alpha: opacity);
}
