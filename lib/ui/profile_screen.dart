import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import 'knowledge_screen.dart';
import 'mcp_screen.dart';
import 'memory_screen.dart';
import 'roles_screen.dart';
import 'settings_screen.dart';
import 'terminal_screen.dart';

/// 我的 Tab：Marvis 风格的分组白卡片列表。
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(memoryServiceProvider);
    final currentTheme = ref.watch(themeProvider);
    final prefs = ref.watch(sharedPreferencesProvider);
    final primary = Theme.of(context).colorScheme.primary;

    void pickTheme(String id) {
      prefs.setString('theme_id', id);
      ref.read(themeProvider.notifier).state = id;
    }

    void pickMode(String mode) {
      prefs.setString('theme_mode', mode);
      ref.read(themeModeProvider.notifier).state =
          mode == 'light' ? ThemeMode.light : (mode == 'dark' ? ThemeMode.dark : ThemeMode.system);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        // ------- 主题配色 -------
        SafeArea(
          bottom: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(0, 16, 0, 12),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('主题配色',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    for (final t in appThemes)
                      GestureDetector(
                        onTap: () => pickTheme(t.id),
                        child: Container(
                          margin: const EdgeInsets.only(left: 10),
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                              color: t.primary, shape: BoxShape.circle),
                          child: currentTheme == t.id
                              ? const Icon(Icons.check_rounded,
                                  size: 16, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('跟随系统')),
                    ButtonSegment(value: 'light', label: Text('浅色')),
                    ButtonSegment(value: 'dark', label: Text('深色')),
                  ],
                  selected: {ref.watch(themeModeProvider).name},
                  onSelectionChanged: (s) => pickMode(s.first),
                ),
              ],
            ),
          ),
        ),
        // ------- Agent 介绍卡 -------
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: surface(context),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 84, height: 84, child: ClipOval(child: Transform.scale(scale: 1.6, alignment: Alignment.topCenter, child: Image.asset(mascotAsset(context), fit: BoxFit.cover, cacheWidth: 480)))),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Pocket Agent',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text('我 24 小时在线，能搜索、算数、读网页，还有记性。',
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: onSurface(context, 0.55))),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      children: ['理智高效', '极简办公', '默默干活']
                          .map((t) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: onSurface(context, 0.05),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(t,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // ------- 功能分组 -------
        _CardGroup(items: [
          _CardItem(
            icon: Icons.build_rounded,
            title: '模型设置',
            trailing: () => const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          _CardItem(
            icon: Icons.lightbulb_rounded,
            title: '长期记忆',
            trailing: () => Text('${memory.notes.length} 条',
                style: TextStyle(
                    fontSize: 13, color: onSurface(context, 0.4))),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MemoryScreen())),
          ),
          _CardItem(
            icon: Icons.auto_stories_rounded,
            title: '知识库',
            trailing: () => const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const KnowledgeScreen())),
          ),
          _CardItem(
            icon: Icons.face_retouching_natural_rounded,
            title: 'Agent 角色',
            trailing: () => const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RolesScreen())),
          ),
          _CardItem(
            icon: Icons.dns_outlined,
            title: 'MCP 服务器',
            trailing: () => const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const McpScreen())),
          ),
          _CardItem(
            icon: Icons.terminal_rounded,
            title: '终端环境',
            subtitle: 'Alpine Linux 沙箱，Agent 可执行命令',
            trailing: () => const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TerminalScreen())),
          ),
        ]),
        const SizedBox(height: 12),
        _CardGroup(items: [
          _CardItem(
            icon: Icons.info_outline_rounded,
            title: '关于',
            trailing: () => Text('V0.1.0',
                style: TextStyle(
                    fontSize: 13, color: onSurface(context, 0.4))),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Pocket Agent V0.1.0 · Flutter 构建'))),
          ),
        ]),
        const SizedBox(height: 12),
        // ------- 清空数据 -------
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('清空所有会话'),
                content: const Text('将删除本机全部会话记录，不可恢复。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('清空',
                          style: TextStyle(color: Color(0xFFD93025)))),
                ],
              ),
            );
            if (ok == true) {
              await ref.read(chatProvider.notifier).clearAllSessions();
            }
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              '清空所有会话',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Color(0xFFD93025),
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}

class _CardItem {
  const _CardItem({
    required this.icon,
    required this.title,
    required this.trailing,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget Function() trailing;
  final VoidCallback onTap;
}

class _CardGroup extends StatelessWidget {
  const _CardGroup({required this.items});

  final List<_CardItem> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(left: 56),
                child: Divider(
                    height: 1, color: onSurface(context, 0.06)),
              ),
            InkWell(
              borderRadius: i == 0
                  ? const BorderRadius.vertical(top: Radius.circular(20))
                  : (i == items.length - 1
                      ? const BorderRadius.vertical(bottom: Radius.circular(20))
                      : null),
              onTap: items[i].onTap,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Row(
                  children: [
                    Icon(items[i].icon,
                        size: 22, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(items[i].title,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                          if (items[i].subtitle != null)
                            Text(items[i].subtitle!,
                                style: TextStyle(
                                    fontSize: 12,
                                    height: 1.3,
                                    color: onSurface(context, 0.4))),
                        ],
                      ),
                    ),
                    items[i].trailing(),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded,
                        size: 22, color: onSurface(context, 0.26)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
