import '../theme.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../models/chat_message.dart';
import '../providers/providers.dart';
import '../services/skill_service.dart';

/// 把 data URL 解成字节。
///
/// 历史数据里可能存在被截断或手工编辑过的 base64，直接 base64Decode 会抛
/// FormatException 并让整棵消息树渲染失败，这里返回 null 由调用方降级展示占位图。
///
/// 结果按 dataUrl 缓存：Image.memory 的缓存键取自 MemoryImage 持有的 bytes
/// 【对象身份】，每次 build 新建的 Uint8List 会让缓存永不命中，导致每帧都重新
/// base64 解码 + JPEG 解码。流式期间 build 每秒跑几十次，一个 20 条消息、
/// 每条带 1600px 照片的会话每帧要解码数 MB，表现为滚动卡顿。
Uint8List? _decodeImage(String dataUrl) {
  final hit = _imageCache[dataUrl];
  if (hit != null) return hit;
  Uint8List? bytes;
  try {
    final b64 = dataUrl.contains(',') ? dataUrl.split(',').last : dataUrl;
    final decoded = base64Decode(b64);
    bytes = decoded.isEmpty ? null : decoded;
  } catch (_) {
    bytes = null;
  }
  // 上限保护：长会话里无限增长会吃掉可观的内存。
  if (_imageCache.length > 32) _imageCache.clear();
  if (bytes != null) _imageCache[dataUrl] = bytes;
  return bytes;
}

/// 以 data URL 为键的解码缓存（进程内有效即可，图片不会在会话外被改写）。
final Map<String, Uint8List> _imageCache = {};

void _showImageViewer(BuildContext context, String dataUrl) {
  final bytes = _decodeImage(dataUrl);
  if (bytes == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('图片数据已损坏，无法显示')));
    return;
  }
  showDialog(
    context: context,
    builder: (_) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: InteractiveViewer(
        maxScale: 4,
        child: Center(child: Image.memory(bytes)),
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
  /// 上次触发自动滚动的流式内容长度，避免每帧都注册 post-frame 回调。
  int _lastScrollLen = -1;

  @override
  void initState() {
    super.initState();
    _inputController.addListener(() {
      final has = _inputController.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    // 技能页点按快捷指令 → 预填输入框。
    // 必须放在 initState：ref.listen 若在 build 里调用，每次重建都会新增一个
    // 监听，且回调里立刻 ref.read().state = '' 会在 build 期间修改状态，
    // 触发 Riverpod 的「build 期间不可修改 provider」断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.listen(prefillProvider, (prev, next) {
        if (next.isNotEmpty) {
          _inputController.text = next;
          _inputController.selection =
              TextSelection.collapsed(offset: next.length);
          ref.read(prefillProvider.notifier).state = '';
        }
      });
    });
  }

  @override
  void dispose() {
    // 释放麦克风：若在识别过程中销毁 widget 而不停止，平台会一直持有录音，
    // 用户下次进页面无法启动识别。
    unawaited(ref.read(voiceProvider).stopListening());
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
    // 必须在清空输入框【之前】拦截。并发守卫在 ChatNotifier.send() 里，
    // 而那时输入框和图片列表已经被清空了：流式期间按回车，用户刚输入的文字
    // 和已选图片会被静默销毁，send() 直接 return，没有任何提示。
    if (ref.read(chatProvider).isStreaming) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在生成回答，请先点击「停止」')),
      );
      return;
    }
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
      // readAsBytes 是异步间隙，widget 可能已被销毁（路由被pop、热重载、
      // 宿主 Activity 销毁）。不检查就 setState 会抛
      // "setState() called after dispose()"。下面的 catch 里有 mounted 判断，
      // 说明这个风险已被识别，只是正常路径漏了。
      if (!mounted) return;
      setState(() =>
          _pendingImages.add('data:image/jpeg;base64,${base64Encode(bytes)}'));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('获取图片失败：$e')));
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
    final chat = ref.watch(chatProvider);
    final session = chat.activeSession;

    // 原来无条件在 build 里注册 post-frame 回调。流式期间每个 AgentDelta
    // 都会 copyWith 触发一次 build，于是每秒注册几十个回调，每个都重启
    // 250ms 的animateTo —— 滚动抖动且动画永远推不到底，回调队列持续膨胀。
    // 改为只在【内容长度真的变了】时注册一次。
    final streamingLen = chat.streamingContent.length;
    if (chat.isStreaming && streamingLen != _lastScrollLen) {
      _lastScrollLen = streamingLen;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
    }

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
                      const Text('Orion Agent',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
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
                    onTap: () =>
                        ref.read(chatProvider.notifier).clearError(),
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
                      child: _PendingThumb(dataUrl: _pendingImages[i]),
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

/// 待发送图片的缩略图；数据损坏时显示占位块而不是让整页崩掉。
class _PendingThumb extends StatelessWidget {
  const _PendingThumb({required this.dataUrl});

  final String dataUrl;

  @override
  Widget build(BuildContext context) {
    final bytes = _decodeImage(dataUrl);
    if (bytes == null) {
      return Container(
        width: 56,
        height: 56,
        color: Colors.black12,
        child: const Icon(Icons.broken_image_outlined,
            size: 22, color: Colors.black38),
      );
    }
    return Image.memory(bytes, width: 56, height: 56, fit: BoxFit.cover);
  }
}

/// 消息里的图片；解码失败时降级为占位块。
class _MessageImage extends StatelessWidget {
  const _MessageImage({required this.dataUrl});

  final String dataUrl;

  @override
  Widget build(BuildContext context) {
    final bytes = _decodeImage(dataUrl);
    if (bytes == null) {
      return Container(
        width: 180,
        height: 100,
        color: Colors.white24,
        child: const Icon(Icons.broken_image_outlined, color: Colors.white54),
      );
    }
    return Image.memory(
      bytes,
      width: 180,
      height: 180,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        width: 180,
        height: 100,
        color: Colors.white24,
        child: const Icon(Icons.broken_image_outlined, color: Colors.white54),
      ),
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
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: MascotAvatar(size: 64, image: mascotAsset(context)),
        ),
        const SizedBox(height: 18),
        Text('你好，今天想做什么？',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w500,
              color: onSurface(context, 1),
            )),
        const SizedBox(height: 18),
        // 与效果图一致：左对齐、按内容宽度收缩的胶囊卡片
        for (final (emoji, text) in _suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => onSuggestion(text),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: surface(context),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 17)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w400)),
                      ),
                    ],
                  ),
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
                      child: _MessageImage(dataUrl: url),
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
                // onSubmitted 的签名是 void Function(String)，不能返回 null；
                // 这里显式分支，未就绪时什么都不做。
                onSubmitted: (_) {
                  if (hasText || hasImages) onSend();
                },
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
                  child: Icon(Icons.arrow_upward_rounded,
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
