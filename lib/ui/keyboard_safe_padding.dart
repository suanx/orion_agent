import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 键盘 insets 残留自愈包裹（2026-10-11 根因修复）。
///
/// ## 症状
/// 云端 Agent 页（全屏路由）push/pop 与 IME 收起动画竞态后，
/// `viewInsets.bottom` 停在「键盘开着」时的旧值不再归零（Flutter
/// Android embedding 的已知问题）。使用它的页面（HomeShell /
/// _CloudAgentPage 都是 `resizeToAvoidBottomInset: false` + 手动
/// `Padding(bottom: kb)`）整个内容被顶上去，底部一大块空白——
/// 表现为「导航栏消失 / 底部错位」，只能重启恢复。
///
/// ## 为什么之前的修复没打中
/// 2026-10-10 的「底栏常驻不折叠」只是让底栏不再随 kb 折叠，
/// 但残留的 kb 值本身仍然把 body 顶起来——卡死态的**可见部分**
/// 消了一半，错位还在。
///
/// ## 自愈逻辑
/// `kb > 0` 但当前**没有任何焦点输入框**（此时键盘必然已关闭）持续
/// 超过 500ms → 判定为残留值，之后一律按 0 处理，直到 insets 真正
/// 归零或键盘再次打开。键盘正常收起动画期间（<500ms）焦点先于
/// insets 归零，判定期避免布局闪跳。
///
/// 不改变正常键盘避让：有焦点时原样透传 kb，行为与直接 Padding 一致。
class KeyboardSafePadding extends StatefulWidget {
  const KeyboardSafePadding({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardSafePadding> createState() => _KeyboardSafePaddingState();
}

class _KeyboardSafePaddingState extends State<KeyboardSafePadding> {
  /// 首次观察到「insets>0 且无焦点」的时刻；null = 不在可疑态。
  DateTime? _stuckSince;

  /// 已判定为残留（在 insets 归零/键盘重新打开前持续钳 0）。
  bool _healed = false;

  Timer? _recheck;

  @override
  void dispose() {
    _recheck?.cancel();
    super.dispose();
  }

  /// 判定期内没有新的 metrics 事件触发重建时，定时重估一次。
  void _scheduleRecheck() {
    _recheck ??= Timer(const Duration(milliseconds: 550), () {
      _recheck = null;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.viewInsetsOf(context).bottom;
    final focused = FocusManager.instance.primaryFocus != null;

    double pad;
    if (kb <= 0) {
      // 一切正常：清除判定状态。
      _stuckSince = null;
      _healed = false;
      pad = 0;
    } else if (focused) {
      // 有焦点输入框：键盘真开着，正常避让。
      _stuckSince = null;
      _healed = false;
      pad = kb;
    } else {
      // 无焦点但 insets>0：要么键盘正在收起（<500ms），要么残留值。
      _stuckSince ??= DateTime.now();
      if (_healed ||
          DateTime.now().difference(_stuckSince!) >
              const Duration(milliseconds: 500)) {
        _healed = true;
        pad = 0;
        debugPrint('KeyboardSafePadding: 键盘 insets 残留 '
            '(${kb.toStringAsFixed(0)}px 且无焦点)，已钳为 0');
      } else {
        pad = kb;
        _scheduleRecheck();
      }
    }

    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: widget.child,
    );
  }
}
