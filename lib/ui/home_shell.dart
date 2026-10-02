import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowSetup());
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
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      drawer: const SessionDrawer(),
      extendBody: true,
      body: IndexedStack(
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
      bottomNavigationBar: _FrostedNavBar(
        index: _tab,
        height: _navHeight,
        onTap: (i) => setState(() => _tab = i),
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
            color: Colors.white.withOpacity(0.72),
            border: Border(
              top: BorderSide(color: Colors.black.withOpacity(0.06)),
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
                                  : Colors.black.withOpacity(0.35),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _navItems[i].label,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight:
                                    i == index ? FontWeight.w700 : FontWeight.w500,
                                color: i == index
                                    ? primary
                                    : Colors.black.withOpacity(0.35),
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
