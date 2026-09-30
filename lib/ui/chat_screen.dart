import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../providers/providers.dart';

/// 对话 Tab（body，无 Scaffold；drawer 由 HomeShell 提供）。
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.onJumpToTab});

  final VoidCallback onJumpToTab;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _inputController.addListener(() {
      final has = _inputController.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (chat.isStreaming) _scrollToBottom();
    });

    final items = <Widget>[];
    if (session != null) {
      for (final m in session.messages) {
        items.add(_MessageBubble(message: m));
      }
    }
    if (chat.isStreaming) {
      items.add(_StreamingBubble(
          content: chat.streamingContent, steps: chat.steps));
    }
    final empty = items.isEmpty;

    return Column(
      children: [
        // ------- 顶栏：汉堡 + 标题 -------
        SafeArea(
          bottom: false,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.menu_rounded, size: 26),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Pocket Agent',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                                color: Color(0xFF3B82F6), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 5),
                          Text('本机 · ${session?.messages.length ?? 0} 条消息',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.black.withOpacity(0.4))),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.history_rounded, size: 24),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ],
            ),
          ),
        ),
        // ------- 错误提示 -------
        if (chat.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEECEC),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded,
                      size: 18, color: Color(0xFFD93025)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(chat.error!,
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFFD93025))),
                  ),
                  GestureDetector(
                    onTap: () => ref.read(chatProvider.notifier).state =
                        chat.copyWith(clearError: true),
                    child: const Icon(Icons.close_rounded,
                        size: 16, color: Color(0xFFD93025)),
                  ),
                ],
              ),
            ),
          ),
        // ------- 消息区 -------
        Expanded(
          child: empty
              ? _EmptyGreeting(
                  onSuggestion: (text) {
                    ref.read(chatProvider.notifier).send(text);
                    Future.delayed(
                        const Duration(milliseconds: 300), _scrollToBottom);
                  },
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (_, i) => items[i],
                ),
        ),
        // ------- 输入栏 -------
        _InputBar(
          controller: _inputController,
          hasText: _hasText,
          isStreaming: chat.isStreaming,
          onSend: _send,
          onStop: () => ref.read(chatProvider.notifier).stop(),
        ),
        const SizedBox(height: 72), // 给磨砂底导航留出空间
      ],
    );
  }
}

class _EmptyGreeting extends StatelessWidget {
  const _EmptyGreeting({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const _suggestions = [
    ('🔍', '联网搜索今天的科技新闻'),
    ('🧮', '帮我算一笔账'),
    ('🌐', '读取一个网页并总结'),
    ('💡', '记住我的偏好设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      children: [
        const SizedBox(height: 24),
        Container(
          width: 84,
          height: 84,
          decoration: const BoxDecoration(
              color: Colors.black, shape: BoxShape.circle),
          child: const Icon(Icons.smart_toy_rounded,
              color: Colors.white, size: 44),
        ),
        const SizedBox(height: 24),
        const Text('你好，今天想做什么？',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 20),
        for (final (emoji, text) in _suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => onSuggestion(text),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(emoji, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(text,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
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
            color: Colors.black,
            borderRadius: BorderRadius.circular(18)
                .copyWith(bottomRight: const Radius.circular(6)),
          ),
          child: SelectableText(message.content,
              style: const TextStyle(color: Colors.white, fontSize: 15)),
        ),
      );
    }

    if (message.role == 'tool') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('🔧 ${message.toolName ?? "tool"} 结果已返回',
              style: TextStyle(
                  fontSize: 12, color: Colors.black.withOpacity(0.45))),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.86),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18)
              .copyWith(bottomLeft: const Radius.circular(6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final tc in message.toolCalls)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('🔧 已调用 ${tc.name}',
                    style: TextStyle(
                        fontSize: 12, color: Colors.black.withOpacity(0.45))),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.86),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18)
              .copyWith(bottomLeft: const Radius.circular(6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(s,
                    style: TextStyle(
                        fontSize: 12, color: Colors.black.withOpacity(0.45))),
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
    required this.hasText,
    required this.isStreaming,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool hasText;
  final bool isStreaming;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              child: const Icon(Icons.add_rounded,
                  size: 24, color: Colors.black54),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => hasText ? onSend() : null,
                decoration: InputDecoration(
                  hintText: '请在此输入任务',
                  hintStyle: TextStyle(
                      color: Colors.black.withOpacity(0.28), fontSize: 15),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            if (isStreaming)
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  icon: const Icon(Icons.stop_rounded,
                      size: 24, color: Colors.black),
                  onPressed: onStop,
                ),
              )
            else if (hasText)
              GestureDetector(
                onTap: onSend,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                      color: Colors.black, shape: BoxShape.circle),
                  child: const Icon(Icons.arrow_upward_rounded,
                      size: 22, color: Colors.white),
                ),
              )
            else
              SizedBox(
                width: 40,
                height: 40,
                child: Icon(Icons.mic_none_rounded,
                    size: 24, color: Colors.black.withOpacity(0.35)),
              ),
          ],
        ),
      ),
    );
  }
}
