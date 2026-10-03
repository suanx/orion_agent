import '../theme.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'glass.dart';
import 'status_bar_area.dart';

import '../models/chat_message.dart';
import '../models/llm_config.dart';
import '../providers/providers.dart';
import '../services/skill_service.dart';
import '../services/tools.dart';

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
  showGlassDialog(
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

    // 没有可用模型时直接拦下并说明原因。ChatNotifier.send() 里也有
    // 同样的守卫，但那时用户已经按下发送、看到按钮无反应，
    // 提示出现在这里更及时。
    final cfg = ref.read(configProvider).activeConfig;
    if (cfg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在「我的 → 模型设置」添加模型服务')),
      );
      return;
    }
    // 必须有可用的聊天模型才能对话。只配了向量模型时明确提示，
    // 而不是让用户对着 /chat/completions 的报错发呆。
    if (cfg.chatModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前提供商下没有聊天模型，无法对话。\n'
            '请到「模型设置 → 该提供商 → 模型」添加一个聊天模型。')),
      );
      return;
    }

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

  /// 居中弹窗选择当前聊天模型。
  ///
  /// 模型列表来自当前提供商的 chatModels；选择写入 defaultChatModel。
  /// 未配置模型时此入口在输入栏不可点（图标置灰），这里再兜底一次。
  Future<void> _pickModel() async {
    final active = ref.read(configProvider).activeConfig;
    final models = active?.chatModels ?? const <ProviderModel>[];
    if (active == null || active.chatModel == null || models.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请先在「我的 → AI 提供商」配置模型服务')));
      return;
    }
    final current = active.chatModel!.name;
    final sel = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        title: const Text('选择模型'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420, maxWidth: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in models)
                  ListTile(
                    dense: true,
                    title: Text(m.name,
                        style: const TextStyle(fontSize: 14.5)),
                    subtitle: m.contextWindow > 0
                        ? Text(
                            // _compactTokens 定义在 _ComposerStatusBar 里
                            //（同类私有静态，同文件可直接引用）
                            '上下文 ${_ComposerStatusBar._compactTokens(m.contextWindow)}',
                            style: const TextStyle(fontSize: 11.5))
                        : null,
                    trailing: m.name == current
                        ? Icon(Icons.check_rounded,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () => Navigator.pop(ctx, m.name),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (sel == null || sel == current) return;
    // ConfigNotifier.upsert 是 void（同步更新内存并落库），不能 await
    ref
        .read(configProvider.notifier)
        .upsert(active.copyWith(defaultChatModel: sel));
  }

  Future<void> _addImage() async {
    final source = await showGlassDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        title: const Text('添加图片'),
        content: Column(
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
    // 思考流的长度也算上：思考期间也要跟随滚动。
    final streamingLen =
        chat.streamingContent.length + chat.streamingReasoning.length;
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
          content: chat.streamingContent,
          reasoning: chat.streamingReasoning,
          steps: chat.steps));
    }
    final empty = items.isEmpty;

    return Column(
      children: [
        // ------- 顶栏：汉堡 + 标题 -------
        // StatusBarArea 把状态栏那条区域也涂成页面底色。
        // SafeArea 只给子节点加 padding、自身不涂背景，edge-to-edge 下
        // 状态栏区域会透出窗口底色（黑边）。
        StatusBarArea(
          child: SafeArea(
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
        const _ComposerStatusBar(),
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
          // 模型选择：麦克风旁的调音图标，点击居中弹窗选择当前模型
          modelName: ref.watch(configProvider).activeConfig?.chatModel?.name,
          onPickModel: _pickModel,
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

class _EmptyGreeting extends StatefulWidget {
  const _EmptyGreeting({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  @override
  State<_EmptyGreeting> createState() => _EmptyGreetingState();
}

class _EmptyGreetingState extends State<_EmptyGreeting> {

  /// 空态展示的条数（从候选池随机抽取）。
  static const _suggestionCount = 6;

  // 候选建议语。每次进入空态随机抽 4 条，避免每次看到同一组。
  static const _allSuggestions = <(String, String)>[
    ('🔍', '联网搜索今天的科技新闻'),
    ('🧮', '帮我算一笔账'),
    ('🌐', '读取一个网页并总结'),
    ('💡', '记住我的偏好设置'),
    ('📰', '汇总今天的重要国际新闻'),
    ('🌤️', '查一下我所在城市的天气'),
    ('🧠', '用一句话解释量子纠缠'),
    ('🍜', '推荐一道十分钟能做完的晚饭'),
    ('✈️', '帮我规划三天的短途旅行'),
    ('📝', '把这段话改得更简洁一些'),
    ('🔢', '计算 1234乘 5678 的结果'),
    ('💰', '算一算每月存三千块一年能存多少'),
    ('🎯', '帮我制定一份本周学习计划'),
    ('📖', '总结一下《活着》讲了什么'),
    ('🛠️', '写一段Python 快速排序代码'),
    ('🌏', '把这段中文翻译成英文'),
    ('🩺', '头痛需要注意些什么'),
    ('🏠', '小户型客厅怎么布置好看'),
  ];

  /// 抽一次存起来。
  ///
  /// 放在 build 里每次重抽会让卡片在用户点按的过程中换掉内容——
  /// 流式输出时每个 delta 都触发 rebuild，用户会点错行。
  late final List<(String, String)> _suggestions;

  @override
  void initState() {
    super.initState();
    _suggestions = _pickSuggestions();
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _suggestions;

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
        for (final (emoji, text) in suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => widget.onSuggestion(text),
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

  /// 从候选池里随机抽 [_suggestionCount] 条（Fisher-Yates 部分洗牌）。
  ///
  /// 每次 build 都会重抽：`_EmptyGreeting` 本身就是空态专用组件，
  /// 只有在真的没有消息时才会被构建，重抽成本可以忽略；而这样
  /// 每次进入对话页都能看到不同的一组建议。
  List<(String, String)> _pickSuggestions() {
    final pool = List<(String, String)>.of(_allSuggestions);
    final rnd = math.Random();
    final n = _suggestionCount.clamp(0, pool.length);
    for (var i = 0; i < n; i++) {
      final j = i + rnd.nextInt(pool.length - i);
      final tmp = pool[i];
      pool[i] = pool[j];
      pool[j] = tmp;
    }
    return pool.sublist(0, n);
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
            // 思考过程：开启思考且模型返回了推理流时展示，可折叠回看。
            if ((message.reasoning ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _ReasoningPanel(text: message.reasoning!),
              ),
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
  const _StreamingBubble({
    required this.content,
    required this.reasoning,
    required this.steps,
  });

  final String content;

  /// 流式思考过程（开启思考且模型返回时非空）。
  final String reasoning;
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
            // 思考阶段（content 还没开始）默认展开实时思考内容；
            // 正文开始后由面板自己收起，保留可展开回看。
            if (reasoning.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _ReasoningPanel(
                  text: reasoning,
                  inProgress: content.isEmpty,
                  initiallyExpanded: true,
                ),
              ),
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(s,
                    style: TextStyle(
                        fontSize: 12, color: onSurface(context, 0.45))),
              ),
            // 思考流本身就是"在进行中"的可视反馈，此时不再叠加转圈；
            // 两者都空才是真正的等待（首字节未到）。
            if (content.isEmpty && reasoning.isEmpty)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (content.isNotEmpty)
              MarkdownBody(data: content),
          ],
        ),
      ),
    );
  }
}

/// 可折叠的思考过程面板。
///
/// - 收起时一行「思考中…/已深度思考」，点击展开；
/// - 展开时限高 220 可滚动，流式新内容自动跟随到底部；
/// - 思考进行中 → 完成的瞬间自动收起（与主流 AI App 的交互一致），
///   用户可再点开回看。
class _ReasoningPanel extends StatefulWidget {
  const _ReasoningPanel({
    required this.text,
    this.inProgress = false,
    this.initiallyExpanded = false,
  });

  final String text;
  final bool inProgress;
  final bool initiallyExpanded;

  @override
  State<_ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<_ReasoningPanel> {
  late bool _expanded = widget.initiallyExpanded;
  final _scroll = ScrollController();
  int _lastLen = 0;

  @override
  void initState() {
    super.initState();
    _lastLen = widget.text.length;
  }

  @override
  void didUpdateWidget(covariant _ReasoningPanel old) {
    super.didUpdateWidget(old);
    // 思考结束：自动收起，让正文接管视觉焦点
    if (old.inProgress && !widget.inProgress && _expanded) {
      _expanded = false;
    }
    // 展开且在思考中：跟随新内容滚到底
    if (_expanded && widget.inProgress && widget.text.length != _lastLen) {
      _lastLen = widget.text.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.psychology_outlined,
                    size: 14, color: onSurface(context, 0.5)),
                const SizedBox(width: 4),
                Text(
                  widget.inProgress ? '思考中…' : '已深度思考',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.5)),
                ),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: onSurface(context, 0.4),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 220),
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: onSurface(context, 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              controller: _scroll,
              child: SelectableText(
                widget.text,
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: onSurface(context, 0.55)),
              ),
            ),
          ),
      ],
    );
  }
}

/// 上下文用量动态图标：环形进度 + 百分比 + 数值，颜色随占用率变化。
class _ContextGauge extends StatelessWidget {
  const _ContextGauge({
    required this.used,
    required this.total,
    required this.onTap,
  });

  final int used;
  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final hasTotal = total > 0;
    final pct = hasTotal ? (used / total).clamp(0.0, 1.0) : null;
    // 占用率分级：<70% 正常色，70-90% 橙，>90% 红
    final color = pct == null
        ? onSurface(context, 0.3)
        : pct > 0.9
            ? const Color(0xFFD93025)
            : pct > 0.7
                ? const Color(0xFFF9AB00)
                : primary;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: pct,
                    strokeWidth: 2.6,
                    color: color,
                    backgroundColor: onSurface(context, 0.08),
                  ),
                  Text(
                    pct == null ? '?' : '${(pct * 100).round()}',
                    style: TextStyle(
                        fontSize: 7.5,
                        fontWeight: FontWeight.w600,
                        color: onSurface(context, 0.55)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 5),
            Text(
              hasTotal
                  ? '${_ComposerStatusBar._compactTokens(used)} / ${_ComposerStatusBar._compactTokens(total)}'
                  : '上下文不限',
              style: TextStyle(fontSize: 11, color: onSurface(context, 0.5)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 上下文用量明细弹窗（居中玻璃样式）：窗口占用 + 真实 Token 统计 +
/// 工具调度轮次（内置 / MCP）+ 自动压缩次数。
void _showContextDialog(BuildContext context, WidgetRef ref) {
  final chat = ref.read(chatProvider);
  final session = chat.activeSession;
  final active = ref.read(configProvider).activeConfig;
  final total = active?.chatModel?.contextWindow ?? 0;
  var est = 0;
  if (session != null) {
    for (final m in session.messages) {
      est += estimateTokens(m.content) + 8;
    }
  }
  final pct = total > 0 ? (est / total).clamp(0.0, 1.0) : null;
  final tokens = chat.sessionPromptTokens + chat.sessionCompletionTokens;

  String row(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13, color: onSurface(context, 0.5))),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      );

  showGlassDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('上下文用量'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pct != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 6,
                backgroundColor: onSurface(ctx, 0.08),
              ),
            ),
            const SizedBox(height: 4),
          ],
          row(
              '上下文窗口',
              total > 0
                  ? '${_ComposerStatusBar._compactTokens(est)} / '
                      '${_ComposerStatusBar._compactTokens(total)} tokens'
                      '（${(pct! * 100).toStringAsFixed(1)}%，估算）'
                  : '该模型未设置窗口大小，不启用自动压缩'),
          row('会话 Token',
              '输入 ${chat.sessionPromptTokens} · 输出 ${chat.sessionCompletionTokens}'
              ' · 合计 $tokens（API 真实用量）'),
          row('工具调度',
              '内置工具 ${chat.toolRoundsBuiltIn} 轮 · MCP 工具 '
              '${chat.toolRoundsMcp} 轮'),
          row('自动压缩',
              '已压缩 ${chat.compressionCount} 次'
              '（占用超窗口 75% 时触发，保留最近 6 条原文）'),
          Text('估算按 CJK 1 字 1 token、其他 4 字符 1 token 计算，'
              '未含工具定义等固定开销。',
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: onSurface(ctx, 0.4))),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
      ],
    ),
  );
}

/// 输入栏上方的状态条：思考开关 + 模型选择 + 上下文长度。
///
/// 没有可用模型时整条置灰并提示，发送按钮同时禁用——避免用户
/// 在未配置的情况下反复点发送却只看到「请先配置模型」。
class _ComposerStatusBar extends ConsumerWidget {
  const _ComposerStatusBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    final active = config.activeConfig;
    final thinking = ref.watch(thinkingProvider);
    final effort = ref.watch(reasoningEffortProvider);
    final ttsOn = ref.watch(ttsEnabledProvider);
    final permission = ref.watch(agentPermissionProvider);
    final hasModel = active?.chatModel != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Row(
        children: [
          // 思考开关 + 强度：点击弹出底部选择（快速 / 低 / 中 / 高）。
          // 之前只有开/关两态，无法控制推理强度；reasoning_effort
          // 参数早就支持 low/medium/high，这里把入口补上。
          _MiniChip(
            icon: Icons.psychology_outlined,
            label: thinking ? '思考·${_effortLabel(effort)}' : '快速',
            enabled: hasModel,
            onTap: hasModel ? () => _pickThinking(context, ref) : null,
          ),
          const SizedBox(width: 8),

          // 朗读开关：控制回答完成后是否自动朗读（Edge TTS）。
          // 与「语音播报」设置页的总开关共用 ttsEnabledProvider；
          // 切换同时写 provider 与 prefs（provider 初值从 prefs 读，
          // 不落盘重启后会弹回）。
          _MiniChip(
            icon: ttsOn ? Icons.volume_up_rounded : Icons.volume_off_outlined,
            label: ttsOn ? '朗读开' : '朗读关',
            enabled: true,
            onTap: () {
              final next = !ttsOn;
              ref.read(ttsEnabledProvider.notifier).state = next;
              unawaited(ref
                  .read(sharedPreferencesProvider)
                  .setBool('tts_enabled', next));
            },
          ),
          const SizedBox(width: 8),

          // 权限模式：限制 Agent 可用的工具集（只读 / 工作区读写 / 完全访问）。
          // 工具暴露与执行双重过滤在 ToolRegistry，切档即时生效。
          _MiniChip(
            icon: Icons.shield_outlined,
            label: permission.label,
            enabled: true,
            onTap: () => _pickPermission(context, ref),
          ),
          const Spacer(),

          // 上下文用量动态图标：环形进度 = 估算占用 / 模型窗口，
          // 颜色随占用率变化（正常→70% 橙→90% 红），点击弹出用量明细。
          // 模型选择已移到输入框内（麦克风旁的调音图标）——
          // 状态条此前塞了五个元素，窄屏上模型选择被挤出可视区。
          if (hasModel)
            _ContextGauge(
              used: _estimateSessionTokens(ref.watch(chatProvider).activeSession),
              total: active!.chatModel!.contextWindow,
              onTap: () => _showContextDialog(context, ref),
            ),
        ],
      ),
    );
  }

  /// 估算当前会话历史占用的 token（不含工具定义等固定开销）。
  static int _estimateSessionTokens(session) {
    if (session == null) return 0;
    var est = 0;
    for (final m in session.messages) {
      est += estimateTokens(m.content) + 8;
    }
    return est;
  }

  /// 弹出思考强度选择。选择结果同时写入 provider 与 prefs：
  /// provider 初值从 prefs 读，不写回的话重启后会弹回。
  Future<void> _pickThinking(BuildContext context, WidgetRef ref) async {
    final prefs = ref.read(sharedPreferencesProvider);
    // 当前选中项：关闭时用空串表示「快速」。
    final current =
        ref.read(thinkingProvider) ? ref.read(reasoningEffortProvider) : '';
    final sel = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        title: const Text('思考强度'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final opt in const [
              ('', '快速回答', '不开启思考，响应更快'),
              ('low', '思考 · 低', '简短推理，速度与深度均衡'),
              ('medium', '思考 · 中', '常规推理强度（默认）'),
              ('high', '思考 · 高', '最充分的推理，耗时与 token 消耗更高'),
            ])
              ListTile(
                title: Text(opt.$2, style: const TextStyle(fontSize: 15)),
                subtitle: Text(opt.$3,
                    style: const TextStyle(fontSize: 12)),
                trailing: current == opt.$1
                    ? const Icon(Icons.check_rounded, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, opt.$1),
              ),
          ],
        ),
      ),
    );
    if (sel == null) return;
    final on = sel.isNotEmpty;
    ref.read(thinkingProvider.notifier).state = on;
    ref.read(reasoningEffortProvider.notifier).state = on ? sel : 'medium';
    unawaited(prefs.setBool('thinking_enabled', on));
    if (on) unawaited(prefs.setString('reasoning_effort', sel));
  }

  /// 弹出权限模式选择。切换同时写 provider 与 prefs，
  /// 并由 chatProvider 的 listen 联动到 ToolRegistry。
  Future<void> _pickPermission(BuildContext context, WidgetRef ref) async {
    final prefs = ref.read(sharedPreferencesProvider);
    final current = ref.read(agentPermissionProvider);
    final sel = await showGlassDialog<AgentPermission>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        title: const Text('权限模式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in AgentPermission.values)
              ListTile(
                leading: const Icon(Icons.shield_outlined, size: 20),
                title: Text(p.label, style: const TextStyle(fontSize: 15)),
                subtitle:
                    Text(p.desc, style: const TextStyle(fontSize: 12)),
                trailing: current == p
                    ? const Icon(Icons.check_rounded, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
    );
    if (sel == null || sel == current) return;
    ref.read(agentPermissionProvider.notifier).state = sel;
    unawaited(prefs.setString('agent_permission', sel.name));
  }

  static String _effortLabel(String effort) => switch (effort) {
        'low' => '低',
        'high' => '高',
        _ => '中',
      };

  /// 128000 → "128K"，1048576 → "1M"，避免长文本把状态条挤爆。
  static String _compactTokens(int n) {
    if (n >= 1000000) {
      final v = n / 1000000;
      return '${v.toStringAsFixed(v % 1 == 0 ? 0 : 1)}M';
    }
    if (n >= 1000) return '${(n / 1000).round()}K';
    return '$n';
  }
}

/// 状态条上的小圆角标签。
class _MiniChip extends StatelessWidget {
  const _MiniChip({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Theme.of(context).colorScheme.primary : onSurface(context, 0.28);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: surface(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(fontSize: 12, color: color, height: 1.2)),
          ],
        ),
      ),
    );
  }
}

/// 模型选择下拉。仅列出聊天模型。
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
    required this.onPickModel,
    this.modelName,
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

  /// 当前聊天模型名（null = 未配置，图标置灰）。
  final String? modelName;
  final VoidCallback onPickModel;

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
            // 模型选择：麦克风旁的调音图标。
            // 之前在输入栏上方的状态条里做下拉，但状态条塞了思考/朗读/
            // 权限/上下文后，窄屏上模型被挤出可视区；移到这里用居中
            // 弹窗选择（tooltip 显示当前模型名）。
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: modelName == null ? '未配置模型' : '当前模型：$modelName',
                icon: Icon(
                  Icons.tune_rounded,
                  size: 22,
                  color: modelName == null
                      ? onSurface(context, 0.2)
                      : onSurface(context, 0.35),
                ),
                onPressed: modelName == null ? null : onPickModel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
