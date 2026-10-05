import '../theme.dart';
import 'glass.dart';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/navigation_service.dart';
import '../services/terminal_service.dart';
import 'about_screen.dart';
import 'chat_screen.dart';
import 'sessions_drawer.dart';
import 'setup_screen.dart';
import 'skills_screen.dart';
import 'profile_screen.dart';
import 'tasks_screen.dart';

/// 应用外壳：4 个 Tab + 磨砂玻璃底部导航。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  static const _navHeight = 64.0;

  void _goChat() => setState(() => _tab = 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowSetup();
      // 冷启动场景：通知回调可能在 runApp 之前就写入了意图，
      // 首帧之后补执行一次（否则会停在默认 Tab）。
      _consumeIntent();
    });
    // 运行中点击通知：切 Tab + 可选预填输入框。
    // 放在 initState 而非 build：build 里注册监听会每次重建都新增一个，
    // 且回调里改 provider 状态会触发「build 期间不可修改 provider」断言。
    ref.listen<NavIntent?>(navIntentProvider, (_, intent) {
      if (intent == null) return;
      // 先清空（见 _consumeIntent 注释），再执行跳转
      ref.read(navIntentProvider.notifier).state = null;
      _applyIntent(intent);
    });
    // 启动自动检查更新：延迟几秒避开启动高峰；
    // 发现新版本弹窗展示（用户要求：每次进入软件都自动检查）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCheckUpdate());
  }

  /// 启动时自动检查更新，发现新版本弹窗展示更新日志。
  Future<void> _autoCheckUpdate() async {
    // 延迟：首帧渲染 + 终端自启任务 + MCP 连接都在抢启动窗口，
    // 更新检查不与它们竞争。
    await Future<void>.delayed(const Duration(seconds: 4));
    final info =
        await ref.read(updateServiceProvider).checkForUpdate(kAppVersion);
    if (info == null || !mounted) return;
    ref.read(pendingUpdateProvider.notifier).state = info;
    if (!mounted) return;
    await showGlassDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 V${info.version}'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前版本 V$kAppVersion，建议更新以获得最新功能与修复。',
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: onSurface(ctx, 0.55))),
                if (info.changelog != null) ...[
                  const SizedBox(height: 12),
                  Text('更新日志',
                      style: TextStyle(
                          fontSize: 12, color: onSurface(ctx, 0.4))),
                  const SizedBox(height: 6),
                  Text(info.changelog!,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.55,
                          color: onSurface(ctx, 0.7))),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('暂不'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              // 跳到关于页：那里有下载进度与安装授权引导
              Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => const AboutScreen()));
            },
            child: const Text('去更新'),
          ),
        ],
      ),
    );
  }

  /// 执行并清空导航意图。
  ///
  /// 刻意【先清空再执行】：若在 ref.listen 回调里同步把意图置 null，
  /// 等于在 provider 的通知过程中再次写同一个 provider，
  /// 行为依赖 Riverpod 内部时序。先清空可确保无论监听何时触发都不会递归。
  void _consumeIntent() {
    final intent = ref.read(navIntentProvider);
    if (intent == null) return;
    // 先置空再改状态：setState 与写prefillProvider 都在之后
    ref.read(navIntentProvider.notifier).state = null;
    _applyIntent(intent);
  }

  void _applyIntent(NavIntent intent) {
    if (!mounted) return;
    if (intent.tab != _tab) {
      setState(() => _tab = intent.tab);
    }
    if (intent.prefill.isNotEmpty) {
      // 交给 ChatScreen 的输入框（它已在监听 prefillProvider）
      ref.read(prefillProvider.notifier).state = intent.prefill;
    }
  }

  /// 首次运行：检测终端环境，全部缺失时引导到下载向导页。
  Future<void> _maybeShowSetup() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool('terminal_setup_done') ?? false) return;
    try {
      final term = ref.read(terminalServiceProvider);
      var anyInstalled = false;
      for (final d in TerminalDistro.values) {
        if (await term.isInstalled(d)) anyInstalled = true;
      }
      if (!anyInstalled && mounted) {
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SetupScreen()));
      }
    } catch (_) {
      // 检测异常不阻塞应用使用
    } finally {
      await prefs.setBool('terminal_setup_done', true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 键盘弹起时把整棵子树顶上去。
    //
    // 之前用 Scaffold 默认的 resizeToAvoidBottomInsets，键盘弹起后
    // Scaffold 会给body 加一段 bottom padding 把内容顶高，但
    // bottomNavigationBar 是自定义的、不参与这套避让，于是
    // 「被顶高的 body」与「原地不动的底栏」之间留下一条空白带
    // —— 截图里键盘上方那块什么都没有的灰条就是它。
    //
    // 改成自己处理：MediaQuery.viewInsets.bottom 就是键盘高度，
    // 用它整体位移，键盘与内容永远贴合，不留缝。
    final kb = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      // 必须用 scaffoldBg（= scaffoldBackgroundColor，页面底色）而不是
      // surface（卡片色）。Scaffold 的背景会铺满整个窗口，edge-to-edge 下
      // 状态栏那条区域也是它在画；用 surface 会出现「状态栏纯白 + 页面灰白」
      // 的色差带，看起来就像一条边。
      backgroundColor: scaffoldBg(context),
      drawer: SessionDrawer(
        // 抽屉底部「设置」图标直达「我的」Tab
        onGoTab: (t) {
          if (t != _tab) setState(() => _tab = t);
        },
      ),
      extendBody: true,
      // 不设 resizeToAvoidBottomInsets：当前 Flutter stable 已移除该参数
      // （设了会编译失败）。改为整体不依赖 Scaffold 的避让——
      // body 与底栏都用下面的 kb 手动位移，两者同步，不会叠加。
      body: Padding(
        padding: EdgeInsets.only(bottom: kb),
        child: IndexedStack(
          index: _tab,
          children: [
            const ChatScreen(),
            const TasksScreen(),
            SkillsScreen(onUseSkill: (text) {
              if (text.isNotEmpty) {
                ref.read(prefillProvider.notifier).state = text;
              }
              _goChat();
            }),
            const ProfileScreen(),
          ],
        ),
      ),
      bottomNavigationBar: AnimatedSize(
        // 键盘弹起时整条底栏隐藏（用户要求：输入界面不显示底部导航），
        // 键盘收起后展开回原高度。
        //
        // ⚠️ 历史教训（v0.2.2~v0.2.5 白屏/报错根因）：这里曾用
        // AnimatedContainer(clipBehavior: Clip.hardEdge) 且没有 decoration——
        // Container.build 对「clip ≠ none 且 decoration == null」在 release 下
        // 会解引用 decoration!（framework container.dart:413），
        // 抛 "Null check operator used on a null value"，首帧 mount 即崩。
        // AnimatedSize 的裁剪走 ClipRect（不需要 decoration），无此陷阱。
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: kb > 0
            ? const SizedBox(width: double.infinity)
            : _FrostedNavBar(
                index: _tab,
                height: _navHeight,
                // 与 HomeTab 常量保持一致：HomeShell 的 children 顺序即 Tab 顺序，
                // 两处都用常量，任一处调整顺序都会立刻暴露不一致。
                onTap: (i) => setState(() => _tab = i),
              ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem(this.icon, this.activeIcon, this.label);
}

const _navItems = <_NavItem>[
  _NavItem(Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, '对话'),
  _NavItem(Icons.alarm_outlined, Icons.alarm_on_outlined, '任务'),
  _NavItem(Icons.build_outlined, Icons.build_rounded, '技能'),
  _NavItem(Icons.person_outline_rounded, Icons.person_rounded, '我的'),
];

class _FrostedNavBar extends StatelessWidget {
  const _FrostedNavBar({
    required this.index,
    required this.onTap,
    required this.height,
  });

  final int index;
  final ValueChanged<int> onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: surface(context).withValues(alpha: 0.72),
            border: Border(
              top: BorderSide(color: onSurface(context, 0.06)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  for (var i = 0; i < _navItems.length; i++)
                    Expanded(
                      child: InkWell(
                        onTap: () => onTap(i),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              i == index ? _navItems[i].activeIcon : _navItems[i].icon,
                              size: 26,
                              color: i == index
                                  ? primary
                                  : onSurface(context, 0.35),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _navItems[i].label,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight:
                                    i == index ? FontWeight.w500 : FontWeight.w500,
                                color: i == index
                                    ? primary
                                    : onSurface(context, 0.35),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
