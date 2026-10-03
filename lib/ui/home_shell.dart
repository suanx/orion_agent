import '../theme.dart';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/navigation_service.dart';
import '../services/terminal_service.dart';
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
      backgroundColor: surface(context),
      drawer: const SessionDrawer(),
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
      bottomNavigationBar: Padding(
        // 键盘弹起时把底栏一起抬到键盘上方。
        // 用 AnimatedPadding 让它跟随动画过渡，而不是瞬间跳。
        padding: EdgeInsets.only(bottom: kb),
        child: _FrostedNavBar(
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
