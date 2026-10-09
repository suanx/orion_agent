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
    builder: (ctx) {
      // ⚠️ 这里【不能用 Dialog】：Dialog 内部是
      // `Align(alignment: center, child: ...)` 且 width/heightFactor 都是
      // null —— Align 在有界约束下会撑到 constraints.maximum，于是玻璃
      // 面板变成整屏高，内容被顶在中间、上下各留一大片空白
      // （2026-10-06 用户截图反馈「弹窗显示太长」）。
      // 改成 Align + widthFactor/heightFactor = 1：按子组件实际尺寸收缩，
      // 居中显示；再用 maxWidth 400 / maxHeight 80% 兜住超长内容
      // （AlertDialog 内部自带滚动，长表单不会被裁掉）。
      final media = MediaQuery.sizeOf(ctx);
      return Align(
        alignment: Alignment.center,
        widthFactor: 1.0,
        heightFactor: 1.0,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 340,
            maxHeight: media.height * 0.8,
          ),
          child: glassPanel(
            ctx,
            Theme(
              data: Theme.of(ctx).copyWith(
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
      );
    },
  );
}

/// 紧凑弹窗内容（**替代 `AlertDialog`**）。
///
/// ⚠️ 为什么不用 `AlertDialog`：它内部同样是 `Dialog` → `Align(居中, 因子为
/// null)`，在有界约束下会撑到 `constraints.maximum`。也就是说即使
/// `showGlassDialog` 把高度上限压到 80%，AlertDialog 也会把这份上限吃满，
/// 弹窗依旧又宽又长（2026-10-06 用户两次反馈「弹窗还是很宽很长」）。
/// 这里用 `Column(mainAxisSize: MainAxisSize.min)` 真正按内容收缩：
/// - 宽度：内容有多宽就多宽（上限由 showGlassDialog 的 maxWidth 兜底）；
/// - 高度：随内容增长，超长内容（maxHeight 360）内部滚动；
/// - actions 统一右对齐排布。
///
/// 参数与 `AlertDialog` 对齐（title / content / actions），
/// 因此全项目 `AlertDialog(` 可以机械替换为本函数。
/// [backgroundColor] 仅作兼容保留：玻璃面板自带底色，忽略即可。
Widget glassAlertDialog({
  Widget? title,
  Widget? content,
  List<Widget> actions = const [],
  Color? backgroundColor,
  double maxContentHeight = 360,
}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (title != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          // 标题必须显式给颜色：玻璃面板不带 Material AppBar 那种
          // 文本主题继承，浅色主题下 ambient 样式是白色 → 标题不可见
          // （2026-10-10 用户截图：MCP 弹窗标题白字看不见）。
          // 用 onPanelText 取面板文字色：深色=白，浅色=近黑。
          child: Builder(
            builder: (tctx) => DefaultTextStyle(
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: onPanelText(tctx, 0.92),
              ),
              child: title,
            ),
          ),
        ),
      if (content != null)
        Padding(
          padding: EdgeInsets.fromLTRB(20, title == null ? 18 : 0, 20, 0),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxContentHeight),
            child: SingleChildScrollView(
              // 内容通常是 Column(mainAxisSize: min)/Text/TextField：
              // 垂直滚动给出无界高度，min 的 Column 不会报错。
              // content 同样显式给面板文字色（带自己 style 的子组件不受影响）。
              child: Builder(
                builder: (cctx) => DefaultTextStyle(
                  style: TextStyle(color: onPanelText(cctx, 0.85)),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      if (actions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              for (final a in actions) ...[a, const SizedBox(width: 4)],
            ],
          ),
        ),
    ],
  );
}

/// 单文本输入的玻璃对话框。
///
/// 内部创建 [TextEditingController]，弹窗关闭时自动 dispose——调用方
/// 不再持有控制器，杜绝「弹窗关了控制器没释放」的泄漏（P2-6）。
///
/// 返回值：确认 → 输入框内容（已 trim）；取消 / 点遮罩关闭 → null。
Future<String?> showGlassTextDialog({
  required BuildContext context,
  required String title,
  String? labelText,
  String? hint,
  String? initialText,
  String confirmLabel = '确定',
  int maxLines = 1,
}) {
  final ctrl = TextEditingController(text: initialText);
  return showGlassDialog<String>(
    context: context,
    builder: (ctx) => glassAlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: labelText, hintText: hint),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
          child: Text(confirmLabel),
        ),
      ],
    ),
  ).whenComplete(ctrl.dispose);
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
  // localToGlobal 不带 ancestor 返回的是**根坐标系**的全局坐标，
  // 与路由 overlay（全屏）的 LayoutBuilder 坐标系一致，直接可用。
  // ⚠️ 它的 ancestor 参数是 Matrix4 而非 RenderBox，不要画蛇添足。
  final anchorTopLeft = ro.localToGlobal(Offset.zero);
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

      // 水平：以锚点中心对齐，两侧夹紧不出屏。
      // ⚠️ num.clamp 返回 num 不是 double（run#18 的同类坑），
      // 必须显式 toDouble()，否则 Positioned(left:) 编译不过。
      final maxLeft =
          (screenW - width - 12).clamp(12.0, double.infinity).toDouble();
      final double left =
          (anchorRect.center.dx - width / 2).clamp(12.0, maxLeft).toDouble();

      // 垂直：默认面板底边贴在锚点上方 10px；
      // 锚点本身在屏幕上半部（上方放不下菜单）时改到锚点下方。
      final bool above = anchorRect.center.dy >= screenH * 0.35;
      final double top = above
          ? 0
          : (anchorRect.bottom + 10).clamp(0.0, screenH - 120).toDouble();
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
                  // 选项多时（如几十个模型的对话页模型列表）面板不能撑爆
                  // 屏幕，也不能像原来那样直接溢出裁掉——限高 62% 并内部
                  // 滚动（2026-10-06 用户反馈「这个页面不能滑动选择」）。
                  child: ConstrainedBox(
                    // 选项多时（如几十个模型的对话页模型列表）面板不能
                    // 撑爆屏幕——限高 62% 并内部滚动（2026-10-06 用户反馈
                    // 「这个页面不能滑动选择」）。ConstrainedBox 必须在
                    // SingleChildScrollView 外层：内层会收到无界高度，
                    // Column 才能按内容收缩且超出部分走滚动而非溢出。
                    constraints: BoxConstraints(maxHeight: screenH * 0.62),
                    child: SingleChildScrollView(child: builder(ctx)),
                  ),
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
