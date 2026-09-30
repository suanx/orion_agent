import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';

/// 我的 Tab：Marvis 风格的分组白卡片列表。
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(memoryServiceProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 20),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                      color: Colors.black, shape: BoxShape.circle),
                  child: const Icon(Icons.person_rounded,
                      color: Colors.white, size: 28),
                ),
                const SizedBox(width: 12),
                const Text('suanx',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
        // ------- Agent 介绍卡 -------
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: const BoxDecoration(
                    color: Colors.black, shape: BoxShape.circle),
                child: const Icon(Icons.smart_toy_rounded,
                    color: Colors.white, size: 44),
              ),
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
                            color: Colors.black.withOpacity(0.55))),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      children: ['理智高效', '极简办公', '默默干活']
                          .map((t) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.05),
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
                    fontSize: 13, color: Colors.black.withOpacity(0.4))),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MemoryScreen())),
          ),
        ]),
        const SizedBox(height: 12),
        _CardGroup(items: [
          _CardItem(
            icon: Icons.info_outline_rounded,
            title: '关于',
            trailing: () => Text('V0.1.0',
                style: TextStyle(
                    fontSize: 13, color: Colors.black.withOpacity(0.4))),
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
              color: Colors.white,
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
  });

  final IconData icon;
  final String title;
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(left: 56),
                child: Divider(
                    height: 1, color: Colors.black.withOpacity(0.06)),
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
                    Icon(items[i].icon, size: 22, color: Colors.black),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(items[i].title,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    items[i].trailing(),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right_rounded,
                        size: 22, color: Colors.black26),
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
