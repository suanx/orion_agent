import 'dart:async';

import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import 'memory_screen.dart';
import 'token_stats_screen.dart';

/// 抽屉：会话历史（Marvis 风格：大标题 + 浅灰圆角新建按钮 + 列表）。
///
/// [onGoTab]：点击快捷入口需要切到主 Tab（如「设置」直达「我的」）时回调，
/// 由 HomeShell 提供切换逻辑；为 null 时该入口隐藏。
class SessionDrawer extends ConsumerWidget {
  const SessionDrawer({super.key, this.onGoTab});

  final ValueChanged<int>? onGoTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider);
    final sessions = chat.sessions;

    return Drawer(
      backgroundColor: surface(context),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 24, 0, 16),
                child: Text(
                  'Orion Agent',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    backgroundColor: onSurface(context, 0.05),
                    foregroundColor: onSurface(context, 1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () {
                    ref.read(chatProvider.notifier).newSession();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.add_comment_outlined, size: 20),
                  label: const Text('新建对话',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: sessions.isEmpty
                    ? Center(
                        child: Text('暂无历史会话',
                            style: TextStyle(color: onSurface(context, 0.38))))
                    : ListView.builder(
                        itemCount: sessions.length,
                        itemBuilder: (_, i) {
                          final s = sessions[i];
                          final active = s.id == chat.activeSessionId;
                          return ListTile(
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            selected: active,
                            selectedTileColor: onSurface(context, 0.04),
                            leading: Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 20,
                              color: active
                                  ? Theme.of(context).colorScheme.primary
                                  : onSurface(context, 0.38),
                            ),
                            title: Text(
                              s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: active
                                    ? FontWeight.w500
                                    : FontWeight.w500,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                ref
                                    .read(chatProvider.notifier)
                                    .deleteSession(s.id);
                                // 多端同步：删除要传播到其它设备，
                                // 记入待删队列由下次同步上传 tombstone
                                unawaited(ref
                                    .read(cloudSyncServiceProvider)
                                    .markSessionDeleted(s.id));
                              },
                            ),
                            onTap: () {
                              ref
                                  .read(chatProvider.notifier)
                                  .selectSession(s.id);
                              Navigator.of(context).pop();
                            },
                          );
                        },
                      ),
              ),
              // ------- 底部快捷入口：设置 / 记忆 / Token 统计 -------
              if (onGoTab != null) _QuickActions(onGoTab: onGoTab!),
            ],
          ),
        ),
      ),
    );
  }
}

/// 抽屉底部的三个快捷图标，并排一行。
class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onGoTab});

  final ValueChanged<int> onGoTab;

  @override
  Widget build(BuildContext context) {
    final tint = onSurface(context, 0.55);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: IconButton(
              tooltip: '设置（我的）',
              icon: Icon(Icons.settings_outlined, size: 24, color: tint),
              onPressed: () {
                Navigator.of(context).pop();
                onGoTab(3); // Tab 顺序与 HomeShell 保持一致：我的
              },
            ),
          ),
          Expanded(
            child: IconButton(
              tooltip: '长期记忆',
              // 与「我的」页长期记忆图标保持一致（芯片 = 记忆）。
              icon: Icon(Icons.memory_outlined, size: 24, color: tint),
              onPressed: () => Navigator.of(context)
                ..pop()
                ..push(MaterialPageRoute(builder: (_) => const MemoryScreen())),
            ),
          ),
          Expanded(
            child: IconButton(
              tooltip: 'Token 统计',
              icon: Icon(Icons.insights_outlined, size: 24, color: tint),
              onPressed: () => Navigator.of(context)
                ..pop()
                ..push(
                    MaterialPageRoute(builder: (_) => const TokenStatsScreen())),
            ),
          ),
        ],
      ),
    );
  }
}
