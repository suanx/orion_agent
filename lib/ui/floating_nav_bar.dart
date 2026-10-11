import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 底部导航 Tab 条目（图标/选中图标/文案）。
class NavBarItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const NavBarItem(this.icon, this.activeIcon, this.label);
}

/// Tab 顺序与 HomeShell 的 IndexedStack children 一致，两处共用本常量，
/// 任一处调整顺序都会立刻暴露不一致。
const navBarItems = <NavBarItem>[
  NavBarItem(Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, '对话'),
  NavBarItem(Icons.alarm_outlined, Icons.alarm_on_outlined, '任务'),
  NavBarItem(Icons.build_outlined, Icons.build_rounded, '技能'),
  NavBarItem(Icons.person_outline_rounded, Icons.person_rounded, '我的'),
];

/// 悬浮液态玻璃底栏（2026-10-11）：
/// - 悬浮：四边留白、圆角胶囊造型，投影让它「漂」在内容之上；
///   extendBody 下页面内容从栏后穿过，磨砂实时模糊的就是底下内容，
///   液态玻璃的通透感来自这里。
/// - 液态玻璃：BackdropFilter 模糊 + 半透明表面渐变 + 左上高光sheen。
/// - 点击特效：按压缩放回弹（Listener+AnimatedScale）+ 水波纹
///   （InkWell）+ 选中项药丸高亮（AnimatedContainer）。
///
/// 2026-10-11 从 home_shell.dart 抽出为公共组件：云端 Agent 页
/// （_CloudAgentPage）是独立全屏路由、没有 HomeShell，此前它没有底栏，
/// 底部留一条空白带——用户感知为「切到云端后导航栏消失」。现在主页与
/// 云端页共用本组件；云端页 onTap 里先记账导航意图再退出本页。
class FloatingGlassNavBar extends StatelessWidget {
  const FloatingGlassNavBar({
    super.key,
    required this.index,
    required this.onTap,
    required this.height,
  });

  final int index;
  final ValueChanged<int> onTap;
  final double height;

  static const _radius = 30.0;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      // 悬浮留白：左右与底部都不贴边，SafeArea 负责手势条以上的净空。
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      // 投影必须画在 ClipRRect 外面，否则会被裁掉。
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context)
                  .colorScheme
                  .shadow
                  .withValues(alpha: 0.16),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    surface(context).withValues(alpha: 0.80),
                    surface(context).withValues(alpha: 0.64),
                  ],
                ),
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(color: onSurface(context, 0.10)),
              ),
              // 玻璃高光：左上亮、右下微返光的液态质感。
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_radius),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.14),
                    Colors.white.withValues(alpha: 0.0),
                    Colors.white.withValues(alpha: 0.05),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: height,
                  child: Row(
                    children: [
                      for (var i = 0; i < navBarItems.length; i++)
                        Expanded(
                          child: _NavTile(
                            item: navBarItems[i],
                            selected: i == index,
                            primary: primary,
                            onTap: () => onTap(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个导航项：按压缩放回弹 + 水波纹 + 选中药丸高亮。
class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.item,
    required this.selected,
    required this.primary,
    required this.onTap,
  });

  final NavBarItem item;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected
        ? widget.primary
        : onSurface(context, 0.38);
    // Listener 而非 GestureDetector：只读指针事件、不参与手势竞技场，
    // 与 InkWell 的 tap 互不干扰。
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: InkWell(
        onTap: () {
          // 触觉反馈（2026-10-11）：导航切换是高频关键交互，
          // 全项目此前零触觉反馈，从导航开始补。
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        borderRadius: BorderRadius.circular(22),
        splashColor: widget.primary.withValues(alpha: 0.10),
        highlightColor: widget.primary.withValues(alpha: 0.05),
        child: AnimatedScale(
          scale: _pressed ? 0.86 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: widget.selected
                  ? widget.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.selected ? widget.item.activeIcon : widget.item.icon,
                  size: 25,
                  color: color,
                ),
                const SizedBox(height: 2),
                Text(
                  widget.item.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
