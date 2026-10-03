import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 通知点击的 payload 契约。
///
/// 通知的 `payload` 是字符串（平台只能传字符串），这里集中定义取值，
/// 避免各处硬编码字面量拼错。未知 payload 一律忽略。
class NavPayload {
  const NavPayload._();

  /// 跳到「对话」Tab。
  static const chat = 'chat';

  /// 跳到「任务」Tab。
  static const tasks = 'tasks';

  /// 跳到「我的」Tab。
  static const profile = 'profile';
}

/// 底部导航 Tab 索引。顺序必须与 HomeShell 的 _navItems 一致。
class HomeTab {
  const HomeTab._();

  static const chat = 0;
  static const tasks = 1;
  static const skills = 2;
  static const profile = 3;
}

/// 全局导航意图：由通知点击等外部入口写入，HomeShell 监听后执行跳转。
///
/// 为什么用 provider 而不只是 navigatorKey：
/// - [NavIntent] 表达的是「要跳到哪个 Tab」，HomeShell 才知道怎么跳（它持有 _tab）；
///   navigatorKey 只能 push/pop，无法直接改底部 Tab 的选中态。
/// - 冷启动场景：通知回调可能在 runApp 之前就触发。此时无处可导航，
///   所以先记下意图，HomeShell 首帧读到后再执行（见 HomeShell.initState）。
///   这也顺带修复了"App 被系统杀死后点通知进来，落在任务页而非对话页"的问题。
class NavIntent {
  /// 目标 Tab 索引。
  final int tab;

  /// 需要携带的输入框预填文本（如从通知跳回某个会话继续提问）。
  final String prefill;

  /// 自增序号：即使 target 与 prefill 都与上次相同也要触发一次跳转，
  /// 否则连续点两条相同通知会被 StateProvider 的相等判断吞掉。
  final int seq;

  const NavIntent(this.tab, {this.prefill = '', required this.seq});

  @override
  bool operator ==(Object other) =>
      other is NavIntent &&
      other.tab == tab &&
      other.prefill == prefill &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(tab, prefill, seq);
}

/// 当前待处理的导航意图（无则为 null）。
///
/// 写入方：[NavigationService.handlePayload] / `goToTab`。
/// 读取方：HomeShell（监听并执行）。
final navIntentProvider = StateProvider<NavIntent?>((ref) => null);

/// 序列号自增源。与 [NavIntent.seq] 配合保证连续相同目标也能触发。
final _navSeqProvider = StateProvider<int>((ref) => 0);

/// 全局导航入口。
///
/// 之所以做成 service 而不是散落在各处：通知点击（冷/热启动）、快捷指令、
/// 后续可能的深链都需要同一套跳转逻辑，且都要能"先记账后执行"。
class NavigationService {
  // 用 Ref 而非 ProviderRef：Provider 回调拿到的就是 ProviderRef，
  // 它是 Ref 的子类型，向上赋值合法；写 Ref 也便于将来在别处构造。
  NavigationService(this._ref);

  final Ref _ref;

  /// 跳到指定 Tab。
  void goToTab(int tab, {String prefill = ''}) {
    final seq = _ref.read(_navSeqProvider.notifier).state + 1;
    _ref.read(_navSeqProvider.notifier).state = seq;
    _ref.read(navIntentProvider.notifier).state =
        NavIntent(tab, prefill: prefill, seq: seq);
  }

  /// 处理通知 payload。未知 payload 返回 false，便于调用方记日志。
  bool handlePayload(String? payload) {
    switch (payload) {
      case NavPayload.chat:
        goToTab(HomeTab.chat);
        return true;
      case NavPayload.tasks:
        goToTab(HomeTab.tasks);
        return true;
      case NavPayload.profile:
        goToTab(HomeTab.profile);
        return true;
      default:
        debugPrint('notification: 未知 payload「$payload」，已忽略');
        return false;
    }
  }
}

final navigationServiceProvider = Provider<NavigationService>(
  (ref) => NavigationService(ref),
);
