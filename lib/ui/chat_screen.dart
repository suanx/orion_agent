import '../theme.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../models/chat_message.dart';
import '../providers/providers.dart';
import '../services/skill_service.dart';

Uint8List _decodeImage(String dataUrl) {
  final b64 = dataUrl.contains(',') ? dataUrl.split(',')[1] : dataUrl;
  return base64Decode(b64);
}

void _showImageViewer(BuildContext context, String dataUrl) {
  showDialog(
    context: context,
    builder: (_) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: InteractiveViewer(
        maxScale: 4,
        child: Center(child: Image.memory(_decodeImage(dataUrl))),
      ),
    ),
  );
}

/// 对话 Tab（body，无 Scaffold；drawer 由 HomeShell 提供）。
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _pendingImages = <String>[]; // data URL
  bool _hasText = false;
  bool _listening = false;

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
    var text = _inputController.text.trim();
    if (text.isEmpty && _pendingImages.isEmpty) return;

    // 「/技能名 参数」展开为技能提示词模板
    if (text.startsWith('/')) {
      final body = text.substring(1);
      final spaceIdx = body.indexOf(' ');
      final name = spaceIdx == -1 ? body : body.substring(0, spaceIdx);
      final args = spaceIdx == -1 ? '' : body.substring(spaceIdx + 1);
      final skill = ref.read(skillServiceProvider).findByName(name);
      if (skill == null) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('未找到技能「$name」，可在技能页创建')));
        return;
      }
      text = SkillService.expand(skill, args);
    }

    if (text.isEmpty && _pendingImages.isEmpty) return;
    final images = List<String>.of(_pendingImages);
    _inputController.clear();
    setState(_pendingImages.clear);
    ref.read(chatProvider.notifier).send(text, images: images);
    Future.delayed(const Duration(milliseconds: 300), _scrollToBottom);
  }

  Future<void> _toggleMic() async {
    final voice = ref.read(voiceProvider);
    if (voice.isListening) {
      await voice.stopListening();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final ok = await voice.startListening(onText: (text) {
      if (!mounted || text.isEmpty) return;
      setState(() {
        _inputController.text = text;
        _inputController.selection =
            TextSelection.collapsed(offset: text.length);
      });
    });
    if (!mounted) return;
    if (ok) {
      setState(() => _listening = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('语音识别不可用，请检查麦克风权限')));
    }
  }

  Future<void> _addImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final picked = await ImagePicker()
          .pickImage(source: source, imageQuality: 80, maxWidth: 1600);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      setState(() =>
          _pendingImages.add('data:image/jpeg;base64,${base64Encode(bytes)}'));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取图片失败：$e')));
      }
    }
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
    // 技能页点按快捷指令 → 预填输入框
    ref.listen(prefillProvider, (prev, next) {
      if (next.isNotEmpty) {
        _inputController.text = next;
        _inputController.selection =
            TextSelection.collapsed(offset: next.length);
        ref.read(prefillProvider.notifier).state = '';
      }
    });

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
                            decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 5),
                          Text('本机 · ${session?.messages.length ?? 0} 条消息',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: onSurface(context, 0.4))),
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
        // ------- 待发送图片 -------
        if (_pendingImages.isNotEmpty)
          SizedBox(
            height: 64,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              itemCount: _pendingImages.length,
              itemBuilder: (_, i) => Stack(
                children: [
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(_decodeImage(_pendingImages[i]),
                          width: 56, height: 56, fit: BoxFit.cover),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => setState(() => _pendingImages.removeAt(i)),
                      child: Container(
                        decoration: const BoxDecoration(
                            color: Colors.white, shape: BoxShape.circle),
                        child: const Icon(Icons.cancel_rounded,
                            size: 18, color: Colors.black54),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        // ------- 输入栏 -------
        _InputBar(
          controller: _inputController,
          hasText: _hasText,
          hasImages: _pendingImages.isNotEmpty,
          isStreaming: chat.isStreaming,
          isListening: _listening,
          onSend: _send,
          onStop: () => ref.read(chatProvider.notifier).stop(),
          onAddImage: _addImage,
          onMic: _toggleMic,
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
        SizedBox(width: 84, height: 84, child: ClipOval(child: Transform.scale(scale: 1.6, alignment: Alignment.topCenter, child: Image.asset(mascotAsset(context), fit: BoxFit.cover, cacheWidth: 480)))),
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
                  color: surface(context),
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
      final hasImages = message.images.isNotEmpty;
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: hasImages
              ? const EdgeInsets.all(6)
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(18)
                .copyWith(bottomRight: const Radius.circular(6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final url in message.images)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: GestureDetector(
                    onTap: () => _showImageViewer(context, url),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _decodeImage(url),
                        width: 180,
                        height: 180,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 180,
                          height: 100,
                          color: Colors.white24,
                          child: const Icon(Icons.broken_image_outlined,
                              color: Colors.white54),
                        ),
                      ),
                    ),
                  ),
                ),
              if (message.content.isNotEmpty)
                SelectableText(message.content,
                    style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 15)),
            ],
          ),
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
            color: onSurface(context, 0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('🔧 ${message.toolName ?? "tool"} 结果已返回',
              style: TextStyle(
                  fontSize: 12, color: onSurface(context, 0.45))),
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
          color: surface(context),
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
                        fontSize: 12, color: onSurface(context, 0.45))),
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
          color: surface(context),
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
                        fontSize: 12, color: onSurface(context, 0.45))),
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
    required this.hasImages,
    required this.isStreaming,
    required this.isListening,
    required this.onSend,
    required this.onStop,
    required this.onAddImage,
    required this.onMic,
  });

  final TextEditingController controller;
  final bool hasText;
  final bool hasImages;
  final bool isStreaming;
  final bool isListening;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAddImage;
  final VoidCallback onMic;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        decoration: BoxDecoration(
          color: surface(context),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: onSurface(context, 0.04),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                icon: const Icon(Icons.add_rounded,
                    size: 24, color: Colors.black54),
                onPressed: onAddImage,
              ),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => (hasText || hasImages) ? onSend() : null,
                decoration: InputDecoration(
                  hintText: '请在此输入任务',
                  hintStyle: TextStyle(
                      color: onSurface(context, 0.28), fontSize: 15),
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
                  icon: Icon(Icons.stop_rounded,
                      size: 24, color: Theme.of(context).colorScheme.primary),
                  onPressed: onStop,
                ),
              )
            else if (hasText || hasImages)
              GestureDetector(
                onTap: onSend,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle),
                  child: const Icon(Icons.arrow_upward_rounded,
                      size: 22, color: Theme.of(context).colorScheme.onPrimary),
                ),
              )
            else
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                    size: 24,
                    color: isListening
                        ? const Color(0xFFD93025)
                        : onSurface(context, 0.35),
                  ),
                  onPressed: onMic,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
