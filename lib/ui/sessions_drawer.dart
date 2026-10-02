import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// 抽屉：会话历史（Marvis 风格：大标题 + 浅灰圆角新建按钮 + 列表）。
class SessionDrawer extends ConsumerWidget {
  const SessionDrawer({super.key});

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
                  'Pocket Agent',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    backgroundColor: onSurface(context, 0.05),
                    foregroundColor: onSurface(context),
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
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: sessions.isEmpty
                    ? const Center(
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
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => ref
                                  .read(chatProvider.notifier)
                                  .deleteSession(s.id),
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
            ],
          ),
        ),
      ),
    );
  }
}
