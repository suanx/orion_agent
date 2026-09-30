import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../providers/providers.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    ref.read(chatProvider.notifier).send(text);
    Future.delayed(const Duration(milliseconds: 300), _scrollToBottom);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final session = chat.activeSession;

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    final items = <Widget>[];
    if (session != null) {
      for (final m in session.messages) {
        items.add(_MessageBubble(message: m));
      }
    }
    if (chat.isStreaming) {
      items.add(_StreamingBubble(content: chat.streamingContent, steps: chat.steps));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(session?.title ?? 'Pocket Agent'),
        actions: [
          IconButton(
            icon: const Icon(Icons.memory_outlined),
            tooltip: '长期记忆',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MemoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      drawer: _SessionDrawer(chat: chat),
      body: SafeArea(
        child: Column(
          children: [
            if (chat.error != null)
              Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.error_outline),
                  title: Text(chat.error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer)),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        ref.read(chatProvider.notifier).state =
                            chat.copyWith(clearError: true),
                  ),
                ),
              ),
            Expanded(
              child: items.isEmpty
                  ? _EmptyHint(onNewChat: () => ref.read(chatProvider.notifier).newSession())
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      itemCount: items.length,
                      itemBuilder: (_, i) => items[i],
                    ),
            ),
            _InputBar(
              controller: _inputController,
              isStreaming: chat.isStreaming,
              onSend: _send,
              onStop: () => ref.read(chatProvider.notifier).stop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.onNewChat});

  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.smart_toy_outlined,
              size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text('你好，我是 Pocket Agent',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('我可以联网搜索、抓网页、精确计算，\n并记住你的长期偏好。'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onNewChat,
            icon: const Icon(Icons.add),
            label: const Text('开始新对话'),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius:
                BorderRadius.circular(16).copyWith(bottomRight: const Radius.circular(4)),
          ),
          child: SelectableText(message.content),
        ),
      );
    }

    if (message.role == 'tool') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('🔧 ${message.toolName ?? "tool"} 结果已返回',
              style: Theme.of(context).textTheme.bodySmall),
        ),
      );
    }

    // assistant
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.86),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius:
              BorderRadius.circular(16).copyWith(bottomLeft: const Radius.circular(4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final tc in message.toolCalls)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('🔧 已调用 ${tc.name}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            if (message.content.isNotEmpty)
              MarkdownBody(data: message.content),
          ],
        ),
      ),
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.content, required this.steps});

  final String content;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius:
              BorderRadius.circular(16).copyWith(bottomLeft: const Radius.circular(4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(s, style: Theme.of(context).textTheme.bodySmall),
              ),
            if (content.isEmpty)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              MarkdownBody(data: content),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.isStreaming,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool isStreaming;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: '输入消息…',
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(
            radius: 22,
            child: isStreaming
                ? IconButton(icon: const Icon(Icons.stop), onPressed: onStop)
                : IconButton(icon: const Icon(Icons.send), onPressed: onSend),
          ),
        ],
      ),
    );
  }
}

class _SessionDrawer extends ConsumerWidget {
  const _SessionDrawer({required this.chat});

  final ChatState chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = chat.sessions;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: () {
                  ref.read(chatProvider.notifier).newSession();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.add),
                label: const Text('新对话'),
              ),
            ),
            Expanded(
              child: sessions.isEmpty
                  ? const Center(child: Text('暂无历史会话'))
                  : ListView.builder(
                      itemCount: sessions.length,
                      itemBuilder: (_, i) {
                        final s = sessions[i];
                        final active = s.id == chat.activeSessionId;
                        return ListTile(
                          selected: active,
                          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${s.messages.length} 条消息',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () {
                              ref.read(chatProvider.notifier).deleteSession(s.id);
                            },
                          ),
                          onTap: () {
                            ref.read(chatProvider.notifier).selectSession(s.id);
                            Navigator.of(context).pop();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
