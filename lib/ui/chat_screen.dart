import '../theme.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'format_utils.dart';
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
  // 图片查看器保持原生全屏（黑色背景 + 双指缩放）。
  // 不走 showGlassDialog：那是「选项/信息」弹窗的玻璃样式，
  // 限宽 400 会把看图体验裁坏；查看器不属于「弹窗选项」范畴。
  showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
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

  /// 待发送的附件。文件已复制到工作区 uploads 目录；[text] 非空表示
  /// 是小体积文本类文件（内容直接并入消息），否则只给模型路径 +
  /// 「用终端工具处理」的提示（zip/apk/办公文档等二进制一律走这条）。
  final _pendingFiles =
      <({String name, String path, String guestPath, int size, String? text})>[];
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

  /// 把消息内容以引用格式（markdown 块引用，多行逐行加 `> ` 前缀）填入
  /// 输入框（v0.2.28-beta：消息长按 → 引用）。光标移到末尾。
  void _quoteToInput(String text) {
    final quoted = text.trim().split('\n').map((l) => '> $l').join('\n');
    final cur = _inputController.text;
    _inputController.text = cur.isEmpty ? '$quoted\n' : '$cur\n$quoted\n';
    _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length);
  }

  /// 选择工具条「发送」（v0.2.31）：把选中文字直接作为新消息发出。
  /// 输入框已有草稿时不覆盖——静默丢字比多一步操作更伤人。
  void _sendSelection(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    if (_inputController.text.trim().isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('输入框有未发送的内容，请先清空再发送选中文字')));
      return;
    }
    _inputController.text = t;
    _inputController.selection = TextSelection.collapsed(offset: t.length);
    _send();
  }

  void _send() {
    var text = _inputController.text.trim();
    if (text.isEmpty && _pendingImages.isEmpty && _pendingFiles.isEmpty) {
      return;
    }

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

    // 附件并入消息正文：
    // - 文本类（小文件能按 UTF-8 解码）：内容直接贴进代码块，模型直接可读
    // - 其它一切格式（zip / apk / pdf / docx / 图片…）：只给工作区路径 +
    //   工具提示。App 侧不解包二进制，而 proot 终端里的 unzip / tar /
    //   python / file 才是处理它们的正确工具（用户 2026-10-05 明确要求）。
    for (final f in _pendingFiles) {
      final sizeMb = (f.size / (1024 * 1024)).toStringAsFixed(
          f.size < 1024 * 1024 ? 2 : 1);
      text = f.text != null
          ? '$text\n\n【附件：${f.name}】\n```text\n${f.text}\n```'
          : '$text\n\n【已上传文件】${f.name}（$sizeMb MB）\n'
              '已上传到工作区（终端内可见）：${f.guestPath}\n'
              '如需查看或处理，请使用终端工具（如 unzip / tar -xf / '
              'cat / python3 读取该路径），不要臆测文件内容。';
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
    setState(() {
      _pendingImages.clear();
      _pendingFiles.clear();
    });
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

  /// 弹出模型选择——锚定在输入栏调音图标上方的浮层。
  ///
  /// 模型列表聚合【所有已启用且就绪的提供商】的聊天模型（副标题标注
  /// 来源提供商），跨提供商选中时同时切换使用中的提供商并记住偏好
  /// （activeId），解决「添加了新供应商但对话页不显示/选不了」的问题。
  /// 未配置模型时此入口在输入栏不可点（图标置灰），这里再兜底一次。
  ///
  /// 【云端模型】额外并入列表底部：它们由后端持 Key、不落盘（换设备
  /// 登录同一账号即自动可用），因此只在本页临时拼进来，选中时需要先
  /// upsert 进本地配置才能被 activeConfig 指向。
  Future<void> _pickModel(BuildContext anchor) async {
    final state = ref.read(configProvider);
    final cloudNotifier = ref.read(cloudModelsProvider.notifier);
    // 点开时若还没拉过（首次进入对话页、或列表还是空的），先补一次拉取。
    // controller 构造时已通过 Future.microtask 触发过，这里是兜底——
    // 用户可能在加载完成前就点了图标，或者后端刚配好供应商还没同步过来。
    if (cloudNotifier.state.configs.isEmpty) {
      await cloudNotifier.load(force: true);
      if (!mounted) return; // 拉取期间页面可能已销毁
    }
    final cloud = ref.read(cloudModelsProvider);
    // (提供商, 模型) 平铺：对话不再局限于「第一个已启用」的提供商
    final entries = <(LlmConfig, ProviderModel)>[
      for (final c in state.configs)
        if (c.enabled && c.ready)
          for (final m in c.chatModels) (c, m),
    ];
    final cloudConfigs = cloud.configs;
    final cloudEntries = <(LlmConfig, ProviderModel)>[
      for (final c in cloudConfigs)
        for (final m in c.chatModels) (c, m),
    ];
    if (entries.isEmpty && cloudEntries.isEmpty) {
      // 两个列表都空：区分是「没登录」「已登录但后端没配供应商」还是
      // 「拉取失败」，给对应的提示而不是笼统地说"去配置模型服务"。
      final email = ref.read(cloudServiceProvider).email;
      final err = cloud.error;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
            email == null
                ? '请先在「我的 → 云服务」登录，即可使用免费云端模型；'
                    '也可自行配置模型服务'
                : (err != null
                    ? '云端模型加载失败：$err'
                    : '暂无云端模型。请在管理台「AI 模型 → 供应商配置」'
                        '录入上游地址与 API Key 后启用'),
          )));
      return;
    }
    final active = state.activeConfig;
    final currentCfgId = active?.id;
    final currentModel = active?.chatModel?.name;
    // 云端额度耗尽时提前告知，但不禁用入口 —— 用户仍可能想看有哪些模型。
    final quota = ref.read(cloudProvider).aiQuota;
    final cloudBlocked = cloudEntries.isNotEmpty && quota.isExhausted;
    final sel = await showGlassAnchoredMenu<(String, String)>(
      context: context,
      anchor: anchor,
      width: 300,
      options: [
        for (final (cfg, m) in entries)
          GlassMenuOption(
            value: (cfg.id, m.name),
            title: m.name,
            subtitle: [
              cfg.name,
              if (m.contextWindow > 0) '上下文 ${compactTokens(m.contextWindow)}',
            ].join(' · '),
            icon: Icons.auto_awesome_outlined,
            checked: cfg.id == currentCfgId && m.name == currentModel,
          ),
        // 云端分组：标题用 provider 名，副标题标出额度与重置时间
        for (final (cfg, m) in cloudEntries)
          GlassMenuOption(
            value: (cfg.id, m.name),
            title: m.name,
            subtitle: [
              cfg.name,
              if (quota.isSupported)
                quota.isExhausted
                    ? '本周额度已用完'
                    : '剩 ${quota.remaining} 轮/${quota.resetText}',
            ].join(' · '),
            icon: quota.isExhausted
                ? Icons.cloud_off_outlined
                : Icons.cloud_done_outlined,
            checked: cfg.id == currentCfgId && m.name == currentModel,
          ),
      ],
    );
    if (!mounted) return; // 浮层关闭前的异步间隙里页面可能已被销毁
    if (sel == null ||
        (sel.$1 == currentCfgId && sel.$2 == currentModel)) {
      return;
    }
    final notifier = ref.read(configProvider.notifier);
    var target = notifier.byId(sel.$1);
    // 云端配置不在本地表里：先写入一份（带 fullUrl 与占位 Key），
    // 之后对话链路与自建配置完全同构，无需特殊分支。
    if (target == null) {
      target = cloudConfigs.where((c) => c.id == sel.$1).firstOrNull;
      if (target == null) return;
      if (cloudBlocked) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('本周云端额度已用完，${quota.resetText}')));
        return;
      }
      notifier.upsert(target.copyWith(defaultChatModel: sel.$2));
      notifier.setActive(target.id);
      return;
    }
    // ConfigNotifier.upsert 是 void（同步更新内存并落库），不能 await
    notifier.upsert(target.copyWith(defaultChatModel: sel.$2));
    if (sel.$1 != currentCfgId) notifier.setActive(sel.$1);
  }

  /// 添加附件——锚定在输入栏加号图标上方的浮层。
  /// 拍照 / 相册走 ImagePicker（图片），「文件」走 FilePicker（文本类附件）。
  Future<void> _addAttachment(BuildContext anchor) async {
    final source = await showGlassAnchoredMenu<String>(
      context: context,
      anchor: anchor,
      options: const [
        GlassMenuOption(
          value: 'camera',
          title: '拍照',
          icon: Icons.photo_camera_outlined,
        ),
        GlassMenuOption(
          value: 'gallery',
          title: '从相册选择',
          icon: Icons.photo_outlined,
        ),
        GlassMenuOption(
          value: 'file',
          title: '文件（任意格式）',
          icon: Icons.description_outlined,
        ),
      ],
    );
    if (source == null) return;
    if (source == 'file') {
      await _pickFile();
      return;
    }
    try {
      final picked = await ImagePicker().pickImage(
          source: source == 'camera'
              ? ImageSource.camera
              : ImageSource.gallery,
          imageQuality: 80,
          maxWidth: 1600);
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

  /// 选择附件：**任意格式**都收（zip / apk / pdf / docx / 图片 / 代码…）。
  ///
  /// 处理策略（2026-10-05 用户要求：不是有终端吗，各种格式交给终端
  /// 的解压/查看命令处理）：
  /// 1. 文件复制到【工作区 uploads/ 目录】——proot 终端与内置文件读写
  ///    工具都以此为根，模型拿到的路径可直接被 unzip / tar / cat 读取；
  /// 2. ≤256KB 且能按 UTF-8 解码 → 内容直接并入消息（代码/配置/日志
  ///    这类最常见，也最省 token）；
  /// 3. 其余（压缩包、安装包、办公文档、二进制…）→ 消息里只给路径 +
  ///    工具提示，不在 App 侧做任何解包。
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        // 不强制读进内存：Android 返回 SAF 缓存路径，copy 是流式的，
        // 大文件不会把内存打爆；只有极少数无路径的平台才落到 bytes。
        withData: false,
      );
      if (!mounted) return;
      final file = result?.files.singleOrNull;
      if (file == null) return;
      if (file.size > 200 * 1024 * 1024) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('文件过大（上限 200MB）')));
        return;
      }
      final ws = await ref.read(terminalServiceProvider).workspaceDir();
      final dir = Directory('$ws/uploads');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      // 文件名做基本清洗（去掉路径分隔符与控制字符），重名加时间戳
      var safe = file.name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
      if (safe.isEmpty) safe = 'file.bin';
      var dest = File('${dir.path}/$safe');
      if (dest.existsSync()) {
        final dot = safe.lastIndexOf('.');
        final stem = dot > 0 ? safe.substring(0, dot) : safe;
        final ext = dot > 0 ? safe.substring(dot) : '';
        safe = '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
        dest = File('${dir.path}/$safe');
      }
      // 后面有多个 await（文件复制/写入），跨异步使用 context 前先取好
      // messenger（use_build_context_synchronously）
      final messenger = ScaffoldMessenger.of(context);
      final src = file.path;
      if (src != null) {
        await File(src).copy(dest.path);
      } else if (file.bytes != null) {
        await dest.writeAsBytes(file.bytes!, flush: true);
      } else {
        messenger.showSnackBar(
            const SnackBar(content: Text('读取文件失败')));
        return;
      }

      // 尝试按文本解码：成功则内容并入消息，失败保持二进制路径模式
      String? asText;
      final len = await dest.length();
      if (len <= 256 * 1024) {
        try {
          asText = utf8.decode(await dest.readAsBytes(), allowMalformed: false);
          if (asText.trim().isEmpty) asText = '（空文件）';
        } catch (_) {
          asText = null; // 二进制
        }
      }
      if (!mounted) return;
      setState(() => _pendingFiles.add((
            name: safe,
            path: dest.path,
            // guest 内工作区固定挂载在 /workspace（见 terminal_service
            // startOn 的 -b 绑定）——给模型/终端的必须是这个路径
            guestPath: '/workspace/uploads/$safe',
            size: len,
            text: asText,
          )));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('添加附件失败：$e')));
    }
  }

  void _scrollToBottom() {
    // Future.delayed / post-frame 回调触发时 State 可能已销毁，
    // 摸已 dispose 的 ScrollController 会抛异常。
    if (!mounted) return;
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
    // 启动即触发一次云端自动同步（内部已按开关/登录态短路，失败静默）
    ref.watch(cloudAutoSyncProvider);
    final chat = ref.watch(chatProvider);
    final session = chat.activeSession;
    // 错误横幅的语义色：跟随主题明暗，不再硬编码浅粉底/红字。
    final errorColor = Theme.of(context).colorScheme.onErrorContainer;

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
        items.add(_MessageBubble(
            message: m, onQuote: _quoteToInput, onSend: _sendSelection));
      }
    }
    // 流式状态是全局单份，streamingSessionId 标记流内容归属的会话：
    // 仅当它正是当前会话时才渲染流式气泡，否则用户切到别的会话
    // 会把别的会话的流式内容「串台」渲染进来。新建会话后
    // activeSessionId 立即等于 streamingSessionId，行为不受影响。
    if (chat.isStreaming &&
        chat.streamingSessionId != null &&
        chat.streamingSessionId == chat.activeSessionId) {
      // 思考行右侧的模式徽章（⚡快速回答 / ⚡深度思考）跟随输入栏当前开关。
      final thinkingOn = ref.watch(thinkingProvider);
      // RepaintBoundary 把流式气泡的重绘限制在气泡自身图层内，
      // 每个 delta 不再连带顶栏/输入栏等整页重绘。
      items.add(RepaintBoundary(
        child: _StreamingBubble(
            content: chat.streamingContent,
            reasoning: chat.streamingReasoning,
            steps: chat.steps,
            modeLabel: thinkingOn ? '深度思考' : '快速回答',
            onQuote: _quoteToInput,
            onSend: _sendSelection),
      ));
    }
    final empty = items.isEmpty;
    if (!empty) {
      // 底部水印：与主流 AI 对话产品一致的生成内容提示。
      items.add(Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Center(
          child: Text('内容由 AI 生成，请注意核实',
              style: TextStyle(fontSize: 11.5, color: onSurface(context, 0.3))),
        ),
      ));
    }

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
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: errorColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(chat.error!,
                        style: TextStyle(fontSize: 13, color: errorColor)),
                  ),
                  GestureDetector(
                    onTap: () =>
                        ref.read(chatProvider.notifier).clearError(),
                    child:
                        Icon(Icons.close_rounded, size: 16, color: errorColor),
                  ),
                ],
              ),
            ),
          ),
        // ------- 消息区 -------
        // 对话字体缩放（我的 → 对话字体）：通过 MediaQuery textScaler
        // 只缩放消息区域的文字（气泡/正文/思考面板），顶栏与输入栏保持
        // 标准字号；scale == 1.0 时与系统默认渲染完全等价。
        Expanded(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(ref.watch(chatFontScaleProvider)),
            ),
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
        ),
        // ------- 待发送文件附件 -------
        if (_pendingFiles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < _pendingFiles.length; i++)
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: surface(context),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.description_outlined,
                            size: 16, color: Colors.blueGrey),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            // 附大小：二进制文件消息里只给路径，大小很关键
                            '${_pendingFiles[i].name}'
                            '（${(_pendingFiles[i].size / 1024).round()} KB'
                            '${_pendingFiles[i].text != null ? ' · 文本' : ''}）',
                            style: const TextStyle(fontSize: 12.5),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: () =>
                              setState(() => _pendingFiles.removeAt(i)),
                          child: Icon(Icons.close_rounded,
                              size: 16, color: onSurface(context, 0.4)),
                        ),
                      ],
                    ),
                  ),
              ],
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
                        // 删除徽标用主题语义色：浅色下是浅灰底深字，
                        // 深色下自动换为深底浅字，不再固定白底。
                        decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            shape: BoxShape.circle),
                        child: Icon(Icons.cancel_rounded,
                            size: 18,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
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
          hasImages: _pendingImages.isNotEmpty || _pendingFiles.isNotEmpty,
          isStreaming: chat.isStreaming,
          isListening: _listening,
          onSend: _send,
          onStop: () => ref.read(chatProvider.notifier).stop(),
          onAddImage: _addAttachment,
          onMic: _toggleMic,
          // 模型选择：麦克风旁的调音图标，点击居中弹窗选择当前模型
          modelName: ref.watch(configProvider).activeConfig?.chatModel?.name,
          onPickModel: _pickModel,
        ),
        // 键盘弹出时磨砂底导航已整体隐藏（见 HomeShell），这个占位
        // 也必须随之归零，否则输入栏与键盘之间会留一条 72px 的空隙；
        // 键盘收起后才恢复给底导航留位。
        SizedBox(height: MediaQuery.viewInsetsOf(context).bottom > 0 ? 0 : 72),
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

/// 正文 Markdown 样式：无气泡纯文本风（参考主流 AI 对话产品），
/// 标题加粗分级、正文 15.5 / 行高 1.6，引用块带主题色左描边。
MarkdownStyleSheet _mdStyleSheet(BuildContext context) {
  final on = onSurface(context, 0.88);
  final onStrong = onSurface(context, 0.95);
  final primary = Theme.of(context).colorScheme.primary;
  // ⚠️ 必须以 fromTheme 为基底再 copyWith，不能用裸构造 MarkdownStyleSheet(...)：
  // 裸构造下 listBulletPadding / checkbox / listIndent / blockquote 等字段为 null，
  // 而 flutter_markdown 内部对它们做非空断言（listBulletPadding! / checkbox! /
  // listIndent!）——消息里出现列表或待办清单即抛
  // "Null check operator used on a null value"，正是 v0.2.1~v0.2.4 白屏根因
  // （docs/PROJECT.md §11.18）。fromTheme 基底保证全字段有默认值。
  //
  // fromTheme 内部 assert bodyMedium.fontSize != null，且 release 下会解引用
  // bodyMedium!.fontSize!——个别平台排版组合可能为 null，这里兜底补一个字号。
  final theme = Theme.of(context);
  final mdTheme = theme.textTheme.bodyMedium?.fontSize != null
      ? theme
      : theme.copyWith(
          textTheme: theme.textTheme
              .merge(const TextTheme(bodyMedium: TextStyle(fontSize: 14))),
        );
  final base = MarkdownStyleSheet.fromTheme(mdTheme);
  return base.copyWith(
    p: TextStyle(fontSize: 15.5, height: 1.6, color: on),
    h1: TextStyle(
        fontSize: 21, height: 1.35, fontWeight: FontWeight.w700, color: onStrong),
    h2: TextStyle(
        fontSize: 18.5, height: 1.35, fontWeight: FontWeight.w700, color: onStrong),
    h3: TextStyle(
        fontSize: 16.5, height: 1.4, fontWeight: FontWeight.w600, color: onStrong),
    h4: TextStyle(
        fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: onStrong),
    strong: TextStyle(fontWeight: FontWeight.w700, color: onStrong),
    em: TextStyle(fontStyle: FontStyle.italic, color: on),
    listBullet: TextStyle(fontSize: 15.5, height: 1.6, color: on),
    blockquote: TextStyle(fontSize: 14.5, height: 1.55, color: onSurface(context, 0.6)),
    blockquoteDecoration: BoxDecoration(
      color: onSurface(context, 0.05),
      borderRadius: BorderRadius.circular(8),
      border: Border(left: BorderSide(color: primary, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    code: TextStyle(
        fontFamily: 'monospace', fontSize: 13, color: onSurface(context, 0.85)),
    // 代码块由 _CodeBlock 自绘（语言栏 + 复制 + 折叠），这里不重复装饰；
    // pre 外壳的内边距也归零，避免卡片外再套一圈空 padding。
    codeblockDecoration: const BoxDecoration(),
    codeblockPadding: EdgeInsets.zero,
    horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: onSurface(context, 0.12)))),
  );
}

/// 带样式与代码块构建器的 Markdown 正文（流式与缓存共用同一入口）。
MarkdownBody _mdBody(BuildContext context, String text) => MarkdownBody(
      data: text,
      styleSheet: _mdStyleSheet(context),
      builders: <String, MarkdownElementBuilder>{'code': _MdCodeBuilder()},
    );

/// 代码构建器：行内 `code` 紧凑样式；``` 围栏块走 _CodeBlock 卡片。
///
/// flutter_markdown 0.7.x 的 builders 是抽象类
/// （`visitElementAfterWithContext`），不是函数 typedef——
/// 直接塞 lambda 会报 map_value_type_not_assignable（CI run 37220472428）。
class _MdCodeBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final isBlock = element.attributes['isCodeBlock'] == 'true';
    final code = element.textContent;
    if (!isBlock) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: onSurface(context, 0.07),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(code,
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: onSurface(context, 0.85))),
      );
    }
    return _CodeBlock(
        code: code, language: element.attributes['language'] ?? '');
  }
}

/// 带样式与代码块构建器的 Markdown 安全入口：自定义渲染管线抛异常时
/// 降级为默认 MarkdownBody（v0.2.4 白屏排障：自定义 builder/styleSheet
/// 是 v0.2.1 起唯一进入启动渲染路径的大改，降级保证消息列表永不白屏）。
Widget _mdSafe(BuildContext context, String text) {
  try {
    return _mdBody(context, text);
  } catch (_) {
    return MarkdownBody(data: text);
  }
}

/// 已完结消息的 Markdown 渲染缓存。
///
/// 流式期间每个 delta 都会触发整页 rebuild，未缓存的 MarkdownBody 会被
/// 重新解析全部消息文本。这里以「亮度|文本」为键缓存解析结果（Widget 实例
/// 复用后 Flutter 会直接跳过该子树的 rebuild），上限 32 条，满了先移除最早条目。
class _CachedMarkdown extends StatelessWidget {
  const _CachedMarkdown({required this.text});

  final String text;

  static final Map<String, Widget> _cache = <String, Widget>{};

  @override
  Widget build(BuildContext context) {
    final key = '${Theme.of(context).brightness.name}|$text';
    final hit = _cache[key];
    if (hit != null) return hit;
    final body = _mdSafe(context, text);
    if (_cache.length >= 32) _cache.remove(_cache.keys.first);
    _cache[key] = body;
    return body;
  }
}

/// 消息正文选择区（v0.2.31）：长按/拖动进入系统原生选择（手柄 +
/// 工具条），工具条按钮为「全选 / 复制 / 引用 / 发送」——替代旧的
/// 长按弹出菜单（v0.2.28-beta），所见即所选、原生手柄可拖动微调。
/// 无文本可选时直接透传，不包一层空的 SelectionArea。
///
/// 注意：区域内部不要放嵌套的 SelectableText（同为可编辑文本会与
/// 区域手势抢长按/双击，出现两套手柄），一律用普通 Text/RichText。
Widget _selectionArea({
  required bool hasText,
  required Widget child,
  void Function(String text)? onQuote,
  void Function(String text)? onSend,
}) {
  if (!hasText) return child;
  return _SelectionAreaShell(onQuote: onQuote, onSend: onSend, child: child);
}

/// 选区缓存壳：`SelectableRegionState`（CI 的 Flutter 3.47.6）没有公开的
/// `getSelectedContent()`，读选中文字只能订阅 `SelectionArea.onSelectionChanged`。
/// 回调里立刻取 `plainText` 存成字符串——`SelectedContent` 对象持选区几何，
/// 拖动手柄后再读会过期/失效。
class _SelectionAreaShell extends StatefulWidget {
  const _SelectionAreaShell({
    required this.child,
    this.onQuote,
    this.onSend,
  });

  final Widget child;
  final void Function(String text)? onQuote;
  final void Function(String text)? onSend;

  @override
  State<_SelectionAreaShell> createState() => _SelectionAreaShellState();
}

class _SelectionAreaShellState extends State<_SelectionAreaShell> {
  /// 最近一次选区文本。选区一变（划词、拖手柄、全选、清空）框架就会
  /// 回调 `onSelectionChanged` 覆盖它；只赋值不 setState——工具条是
  /// Overlay 独立构建，按钮按下时读字段即为最新，无需整树刷新。
  String _selected = '';

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      onSelectionChanged: (content) {
        _selected = content?.plainText ?? '';
      },
      contextMenuBuilder: (ctx, state) {
        // 按钮按下时读 `_selected`（最新选区），兜底工具条构建时的快照，
        // 避免菜单展示期间拖动手柄导致内容过期。
        final snapshot = _selected;
        String current() => _selected.isNotEmpty ? _selected : snapshot;
        TextSelectionToolbarTextButton btn(String label, VoidCallback onPressed) =>
            TextSelectionToolbarTextButton(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onPressed: onPressed,
              child: Text(label),
            );
        return AdaptiveTextSelectionToolbar(
          anchors: state.contextMenuAnchors,
          children: [
            btn('全选', () => state.selectAll(SelectionChangedCause.toolbar)),
            btn('复制', () async {
              final text = current();
              if (text.isEmpty) return;
              await Clipboard.setData(ClipboardData(text: text));
              // 与原生 Android 一致：复制后清掉选区、收起工具条。
              state.clearSelection();
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(const SnackBar(content: Text('已复制')));
              }
            }),
            if (widget.onQuote != null)
              btn('引用', () {
                final text = current();
                if (text.isNotEmpty) widget.onQuote!(text);
                state.clearSelection();
              }),
            if (widget.onSend != null)
              btn('发送', () {
                final text = current();
                if (text.isNotEmpty) widget.onSend!(text);
                state.clearSelection();
              }),
          ],
        );
      },
      child: widget.child,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.onQuote, this.onSend});

  final ChatMessage message;

  /// 选择工具条「引用」：把选中文字交还输入框（v0.2.28-beta 长按菜单保留）。
  final void Function(String text)? onQuote;

  /// 选择工具条「发送」：把选中文字作为新消息发出（v0.2.31）。
  final void Function(String text)? onSend;

  @override
  Widget build(BuildContext context) {
    if (message.role == 'user') {
      // 用户消息：右对齐浅色气泡（primaryContainer 随主题/明暗自适应）。
      final hasImages = message.images.isNotEmpty;
      final bg = Theme.of(context).colorScheme.primaryContainer;
      final fg = Theme.of(context).colorScheme.onPrimaryContainer;
      return _selectionArea(
        hasText: message.content.trim().isNotEmpty,
        onQuote: onQuote,
        onSend: onSend,
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: hasImages
                ? const EdgeInsets.all(6)
                : const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78),
            decoration: BoxDecoration(
              color: bg,
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
                  // 普通 Text：选择统一交给外层 _selectionArea（见其注释），
                  // 嵌套 SelectableText 会与区域手势抢长按。
                  Text(message.content,
                      style: TextStyle(color: fg, fontSize: 15, height: 1.5)),
              ],
            ),
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

    // 助手消息：无气泡纯正文（与主流 AI 对话产品一致），
    // Markdown 直接铺在页面背景上，满宽阅读。
    return _selectionArea(
      hasText: message.content.trim().isNotEmpty ||
          (message.reasoning ?? '').trim().isNotEmpty,
      onQuote: onQuote,
      onSend: onSend,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 思考过程：开启思考且模型返回了推理流时展示，可折叠回看；
            // 调用过的工具/技能名并入思考行（只显示名称，不显示详情）。
            if ((message.reasoning ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _ReasoningPanel(
                  text: message.reasoning!,
                  toolNames: [for (final tc in message.toolCalls) tc.name],
                ),
              ),
            // 无思考行时工具名单独列出（有思考行时名称已在行内，避免重复）。
            if ((message.reasoning ?? '').trim().isEmpty)
              for (final tc in message.toolCalls)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('🔧 已调用 ${tc.name}',
                      style: TextStyle(
                          fontSize: 12, color: onSurface(context, 0.45))),
                ),
            if (message.content.isNotEmpty)
              _CachedMarkdown(text: message.content),
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
    this.modeLabel,
    this.onQuote,
    this.onSend,
  });

  final String content;

  /// 流式思考过程（开启思考且模型返回时非空）。
  final String reasoning;
  final List<String> steps;

  /// 思考行右侧模式徽章（⚡快速回答 / ⚡深度思考），仅流式期间显示。
  final String? modeLabel;

  /// 选择工具条「引用」/「发送」回调（与已完成消息一致，v0.2.31）。
  final void Function(String text)? onQuote;
  final void Function(String text)? onSend;

  @override
  Widget build(BuildContext context) {
    // 工具调用等过程状态（⏳/🔧 行）全部并入下方思考面板滚动展示
    // （2026-10-06 用户要求：不再散落在消息流里逐行显示）。
    // 与已完成消息一致：无气泡纯正文。
    return _selectionArea(
      hasText: content.trim().isNotEmpty || reasoning.trim().isNotEmpty,
      onQuote: onQuote,
      onSend: onSend,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 思考阶段（content 还没开始）默认展开实时思考内容；
            // 正文开始后由面板自己收起，保留可展开回看。
            // 只有工具调用、没有思考流时也渲染，工具调用在面板内滚动显示。
            if (reasoning.isNotEmpty || steps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _ReasoningPanel(
                  text: reasoning,
                  inProgress: content.isEmpty,
                  initiallyExpanded: content.isEmpty,
                  badgeLabel: modeLabel,
                  steps: steps,
                ),
              ),
            // 思考流本身就是"在进行中"的可视反馈，此时不再叠加转圈；
            // 两者都空才是真正的等待（首字节未到）。
            if (content.isEmpty && reasoning.isEmpty && steps.isEmpty)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (content.isNotEmpty)
              _mdSafe(context, content),
          ],
        ),
      ),
    );
  }
}

/// 可折叠的思考过程面板（参考主流 AI App：一行「已思考 >」+ 右侧模式徽章）。
///
/// - 收起时一行「正在思考/已思考」+ 展开箭头，点击展开；
/// - 展开时限高 220 可滚动，流式新内容自动跟随到底部；
/// - 思考进行中 → 完成的瞬间自动收起（与主流 AI App 的交互一致），
///   用户可再点开回看。
class _ReasoningPanel extends StatefulWidget {
  const _ReasoningPanel({
    required this.text,
    this.inProgress = false,
    this.initiallyExpanded = false,
    this.badgeLabel,
    this.toolNames = const [],
    this.steps = const [],
  });

  final String text;
  final bool inProgress;
  final bool initiallyExpanded;

  /// 右侧模式徽章文字（如「快速回答」）；null 不显示。
  final String? badgeLabel;

  /// 已完成消息调用过的工具/技能名（流式过程走 [steps]）。
  final List<String> toolNames;

  /// 流式期间的过程状态行（⏳ 正在调用工具 … / 🔧 工具名）——
  /// 全部并入面板内滚动展示，不再散落在消息流里（2026-10-06 用户要求）。
  final List<String> steps;

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
    // 展开且在思考中：跟随新内容（思考文本或过程状态行）滚到底
    final stepsChanged = old.steps.length != widget.steps.length ||
        (old.steps.isNotEmpty &&
            widget.steps.isNotEmpty &&
            old.steps.last != widget.steps.last);
    if (_expanded &&
        widget.inProgress &&
        (widget.text.length != _lastLen || stepsChanged)) {
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
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 脑子图标标识思考过程（2026-10-06 用户要求替换原展开箭头）；
                    // 展开时用主题色高亮，收起时灰色。
                    Icon(
                      Icons.psychology_rounded,
                      size: 16,
                      color: _expanded
                          ? primary.withValues(alpha: 0.9)
                          : onSurface(context, 0.45),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      widget.inProgress ? '正在思考' : '已思考',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: onSurface(context, 0.5)),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            // 模式徽章（⚡快速回答 / ⚡深度思考），跟随思考开关实时显示。
            if (widget.badgeLabel != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt_rounded, size: 14, color: primary),
                  const SizedBox(width: 2),
                  Text(
                    widget.badgeLabel!,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: primary,
                        decoration: TextDecoration.underline,
                        decorationColor: primary.withValues(alpha: 0.4)),
                  ),
                ],
              ),
          ],
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 220),
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: onSurface(context, 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: onSurface(context, 0.06)),
            ),
            child: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.text.isNotEmpty)
                    // 普通 Text：思考面板在消息选择区内部，选择交给外层
                    // _selectionArea，嵌套 SelectableText 会抢长按手势。
                    Text(
                      widget.text,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.55,
                          color: onSurface(context, 0.55)),
                    ),
                  // 过程状态行（流式：⏳ 正在调用工具 …；历史：工具名清单）。
                  // 与思考文本同处一个滚动区，跟随滚动到底（见 didUpdateWidget）。
                  for (final s in widget.steps)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        s.startsWith('⏳ ') || s.startsWith('🔧 ')
                            ? s.substring(2)
                            : s,
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.45)),
                      ),
                    ),
                  if (widget.steps.isEmpty)
                    for (final name in widget.toolNames)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('已调用 $name',
                            style: TextStyle(
                                fontSize: 12,
                                color: onSurface(context, 0.45))),
                      ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 围栏代码块卡片：语言栏（语言名 + 复制 + 全屏）+ 高亮代码体，
/// 超过 12 行默认折叠到 240 高，底部渐隐 + 圆形箭头展开（参考主流 AI App）。
class _CodeBlock extends StatefulWidget {
  const _CodeBlock({required this.code, required this.language});

  final String code;
  final String language;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;
  bool _unfolded = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _showFull() async {
    await showGlassDialog<void>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: Text(widget.language.isEmpty ? '代码' : widget.language),
        // 不包 SingleChildScrollView：glassAlertDialog 外层已负责滚动，
        // 嵌套的内层滚动组件会抢走拖动手势（2026-10-08 弹窗滑动修复）
        content: SizedBox(
          width: double.maxFinite,
          child: SelectableText(
            widget.code,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 13, height: 1.55),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          FilledButton(onPressed: _copy, child: const Text('复制')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final collapsible = widget.code.split('\n').length > 12;
    final capped = collapsible && !_unfolded;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: onSurface(context, 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: onSurface(context, 0.07)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ------- 语言栏 -------
          Container(
            height: 38,
            padding: const EdgeInsets.only(left: 14, right: 4),
            color: onSurface(context, 0.04),
            child: Row(
              children: [
                Text(
                  widget.language.isEmpty ? '代码' : widget.language.toLowerCase(),
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      color: onSurface(context, 0.55)),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '复制代码',
                  iconSize: 16,
                  icon: Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    color: onSurface(context, _copied ? 0.7 : 0.45),
                  ),
                  onPressed: _copy,
                ),
                IconButton(
                  tooltip: '全屏查看',
                  iconSize: 15,
                  icon: Icon(Icons.open_in_full_rounded,
                      color: onSurface(context, 0.45)),
                  onPressed: _showFull,
                ),
              ],
            ),
          ),
          // ------- 代码体 -------
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: capped ? 240.0 : 6000.0),
            child: Stack(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: _HighlightedCode(code: widget.code),
                ),
                if (capped)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 72,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            onSurface(context, 0.08),
                          ],
                        ),
                      ),
                      alignment: Alignment.bottomCenter,
                      child: GestureDetector(
                        onTap: () => setState(() => _unfolded = true),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: surface(context),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: Icon(Icons.expand_more_rounded,
                              size: 20, color: onSurface(context, 0.6)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 底色与卡片同色系收尾，避免滚动条透出背景
          if (!capped) const SizedBox(height: 0),
        ],
      ),
    );
  }
}

/// 轻量语法高亮：注释/字符串/数字/关键字四类着色（双引号正则，
/// 避免与模板字符串转义冲突）。未覆盖的文本用正文色。
class _HighlightedCode extends StatelessWidget {
  const _HighlightedCode({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final spans = _highlightSpans(code, isDark);
    // 普通 Text.rich：代码块在消息选择区内部，选择交给外层
    // _selectionArea，嵌套 SelectableText 会抢长按手势。
    return Text.rich(
      TextSpan(
        children: spans,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.55,
          color: onSurface(context, 0.85),
        ),
      ),
    );
  }
}

List<TextSpan> _highlightSpans(String code, bool isDark) {
  final comment = isDark ? const Color(0xFF8B949E) : const Color(0xFF6B7280);
  final stringC = isDark ? const Color(0xFF7EE787) : const Color(0xFF0A7F3C);
  final numberC = isDark ? const Color(0xFF79C0FF) : const Color(0xFF0550AE);
  final keywordC = isDark ? const Color(0xFFD2A8FF) : const Color(0xFF8250DF);
  final re = RegExp(
    "(#[^\\n]*|//[^\\n]*|/\\*[\\s\\S]*?\\*/)"
    "|(\"(?:[^\"\\\\\\n]|\\\\.)*\"|\\u0027(?:[^\\u0027\\\\\\n]|\\\\.)*\\u0027)"
    "|\\b(\\d+(?:\\.\\d+)?)\\b"
    "|\\b(const|let|var|function|return|if|else|for|while|import|from|export|class|new|def|async|await|try|catch|true|false|null|None|True|False|SELECT|INSERT|UPDATE|DELETE|FROM|WHERE|JOIN|CREATE|TABLE|print)\\b",
  );
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in re.allMatches(code)) {
    if (m.start > last) {
      spans.add(TextSpan(text: code.substring(last, m.start)));
    }
    final Color c;
    if (m.group(1) != null) {
      c = comment;
    } else if (m.group(2) != null) {
      c = stringC;
    } else if (m.group(3) != null) {
      c = numberC;
    } else {
      c = keywordC;
    }
    spans.add(TextSpan(text: m.group(0), style: TextStyle(color: c)));
    last = m.end;
  }
  if (last < code.length) spans.add(TextSpan(text: code.substring(last)));
  return spans;
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
            // 「647 / 1.0M」数字文本已按用户要求移除（2026-10-05 截图
            // 红框标注「删除」）：只保留圆形进度图标（环 + 百分比），
            // 点击展开用量明细弹窗的行为不变。
          ],
        ),
      ),
    );
  }
}

/// 上下文用量明细弹窗（居中玻璃样式）：窗口占用 + 真实 Token 统计 +
/// 工具调度轮次（内置 / MCP）+ 自动压缩次数。
void _showContextDialog(BuildContext context, WidgetRef ref,
    {required BuildContext anchor}) {
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

  // 锚定在用量图标上方的浮层（点浮层外任意处关闭，无需关闭按钮）
  showGlassAnchoredPanel<void>(
    context: context,
    anchor: anchor,
    width: 296,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('上下文用量',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: onPanelText(ctx, 0.9))),
          const SizedBox(height: 10),
          if (pct != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 6,
                backgroundColor: onPanelText(ctx, 0.10),
              ),
            ),
            const SizedBox(height: 4),
          ],
          _ctxRow(ctx, '上下文窗口',
              total > 0
                  ? '${compactTokens(est)} / '
                      '${compactTokens(total)} tokens'
                      '（${(pct! * 100).toStringAsFixed(1)}%，估算）'
                  : '该模型未设置窗口大小，不启用自动压缩'),
          _ctxRow(ctx, '会话 Token',
              '输入 ${chat.sessionPromptTokens} · 输出 ${chat.sessionCompletionTokens}'
              ' · 合计 $tokens（API 真实用量）'),
          _ctxRow(ctx, '工具调度',
              '内置工具 ${chat.toolRoundsBuiltIn} 轮 · MCP 工具 '
              '${chat.toolRoundsMcp} 轮'),
          _ctxRow(ctx, '自动压缩',
              '已压缩 ${chat.compressionCount} 次'
              '（占用超窗口 75% 时触发，保留最近 6 条原文）'),
          Text('估算按 CJK 1 字 1 token、其他 4 字符 1 token 计算，'
              '未含工具定义等固定开销。',
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: onPanelText(ctx, 0.45))),
        ],
      ),
    ),
  );
}

/// 用量明细浮层的行（锚定面板在玻璃上渲染，用面板专用文字色）。
Widget _ctxRow(BuildContext ctx, String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5, color: onPanelText(ctx, 0.5))),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: onPanelText(ctx, 0.9))),
          ),
        ],
      ),
    );

/// 输入栏上方的状态条：思考开关 + 模型选择 + 上下文长度。
///
/// 没有可用模型时整条置灰并提示，发送按钮同时禁用——避免用户
/// 在未配置的情况下反复点发送却只看到「请先配置模型」。
class _ComposerStatusBar extends ConsumerStatefulWidget {
  const _ComposerStatusBar();

  @override
  ConsumerState<_ComposerStatusBar> createState() =>
      _ComposerStatusBarState();
}

class _ComposerStatusBarState extends ConsumerState<_ComposerStatusBar> {
  /// 上次全量估算 token 的时刻。流式期间每个 delta 都会 rebuild 状态条，
  /// 不节流的话每次都对全部消息逐 rune 扫一遍，消息越多越卡。
  DateTime? _lastTokenEstimate;

  /// 上次估算结果，节流窗口内直接沿用（见 [_estimateSessionTokens]）。
  int _cachedTokenEstimate = 0;

  @override
  Widget build(BuildContext context) {
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
          // 思考开关 + 强度：点击在图标上方弹出浮层（快速 / 低 / 中 / 高）。
          // Builder 包一层拿到 chip 自身的 context，浮层据此锚定。
          Builder(
            builder: (bctx) => _MiniChip(
              icon: Icons.psychology_outlined,
              label: thinking ? '思考·${_effortLabel(effort)}' : '快速',
              enabled: hasModel,
              onTap: hasModel
                  ? () => _pickThinking(context, ref, anchor: bctx)
                  : null,
            ),
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
          // 浮层锚定在盾牌图标上方。
          Builder(
            builder: (bctx) => _MiniChip(
              icon: Icons.shield_outlined,
              label: permission.label,
              enabled: true,
              onTap: () => _pickPermission(context, ref, anchor: bctx),
            ),
          ),
          const Spacer(),

          // 上下文用量动态图标：环形进度 = 估算占用 / 模型窗口，
          // 颜色随占用率变化（正常→70% 橙→90% 红），点击在图标上方
          // 展开用量明细浮层。
          // 模型选择已移到输入框内（麦克风旁的调音图标）——
          // 状态条此前塞了五个元素，窄屏上模型选择被挤出可视区。
          if (hasModel)
            Builder(
              builder: (bctx) {
                final chat = ref.watch(chatProvider);
                return _ContextGauge(
                  used: _estimateSessionTokens(chat.activeSession,
                      streaming: chat.isStreaming),
                  total: active!.chatModel!.contextWindow,
                  // 打开明细弹窗前清掉节流戳：压缩后消息已被替换，
                  // 下次 build 强制重新全量估算一次。
                  onTap: () {
                    _lastTokenEstimate = null;
                    _showContextDialog(context, ref, anchor: bctx);
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  /// 估算当前会话历史占用的 token（不含工具定义等固定开销）。
  ///
  /// 流式期间每个 delta 都触发 rebuild，这里做 300ms 节流：距上次估算
  /// 不足 300ms 且流未结束时直接沿用上次结果，不重扫全部消息。
  /// 流结束（streaming=false）时强制估算一次，保证最终值准确；
  /// 用量明细弹窗打开前会清掉 [_lastTokenEstimate]，同样强制估算一次。
  int _estimateSessionTokens(session, {required bool streaming}) {
    if (session == null) return 0;
    final now = DateTime.now();
    final last = _lastTokenEstimate;
    if (streaming &&
        last != null &&
        now.difference(last) < const Duration(milliseconds: 300)) {
      return _cachedTokenEstimate;
    }
    _lastTokenEstimate = now;
    var est = 0;
    for (final m in session.messages) {
      est += estimateTokens(m.content) + 8;
    }
    _cachedTokenEstimate = est;
    return est;
  }

  /// 弹出思考强度选择——锚定在思考图标上方的浮层。
  /// 选择结果同时写入 provider 与 prefs：
  /// provider 初值从 prefs 读，不写回的话重启后会弹回。
  Future<void> _pickThinking(BuildContext context, WidgetRef ref,
      {required BuildContext anchor}) async {
    final prefs = ref.read(sharedPreferencesProvider);
    // 当前选中项：关闭时用空串表示「快速」。
    final current =
        ref.read(thinkingProvider) ? ref.read(reasoningEffortProvider) : '';
    final sel = await showGlassAnchoredMenu<String>(
      context: context,
      anchor: anchor,
      options: [
        for (final opt in const [
          ('', '快速回答', '不开启思考，响应更快', Icons.bolt_rounded),
          ('low', '思考 · 低', '简短推理，速度与深度均衡', Icons.psychology_outlined),
          ('medium', '思考 · 中', '常规推理强度（默认）', Icons.psychology_outlined),
          ('high', '思考 · 高', '最充分的推理，耗时与 token 消耗更高',
              Icons.psychology_rounded),
        ])
          GlassMenuOption(
            value: opt.$1,
            title: opt.$2,
            subtitle: opt.$3,
            icon: opt.$4,
            checked: current == opt.$1,
          ),
      ],
    );
    if (!mounted) return; // 浮层关闭前的异步间隙里页面可能已被销毁
    if (sel == null) return;
    final on = sel.isNotEmpty;
    ref.read(thinkingProvider.notifier).state = on;
    ref.read(reasoningEffortProvider.notifier).state = on ? sel : 'medium';
    unawaited(prefs.setBool('thinking_enabled', on));
    if (on) unawaited(prefs.setString('reasoning_effort', sel));
  }

  /// 弹出权限模式选择——锚定在盾牌图标上方的浮层。
  /// 切换同时写 provider 与 prefs，并由 chatProvider 的 listen 联动到
  /// ToolRegistry。
  Future<void> _pickPermission(BuildContext context, WidgetRef ref,
      {required BuildContext anchor}) async {
    final prefs = ref.read(sharedPreferencesProvider);
    final current = ref.read(agentPermissionProvider);
    final sel = await showGlassAnchoredMenu<AgentPermission>(
      context: context,
      anchor: anchor,
      options: [
        for (final p in AgentPermission.values)
          GlassMenuOption(
            value: p,
            title: p.label,
            subtitle: p.desc,
            icon: switch (p) {
              AgentPermission.readOnly => Icons.lock_outlined,
              AgentPermission.workspace => Icons.back_hand_outlined,
              AgentPermission.full => Icons.gpp_maybe_outlined,
            },
            checked: current == p,
          ),
      ],
    );
    if (!mounted) return; // 浮层关闭前的异步间隙里页面可能已被销毁
    if (sel == null || sel == current) return;
    ref.read(agentPermissionProvider.notifier).state = sel;
    unawaited(prefs.setString('agent_permission', sel.name));
  }

  static String _effortLabel(String effort) => switch (effort) {
        'low' => '低',
        'high' => '高',
        _ => '中',
      };
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
  final VoidCallback onMic;

  /// 当前聊天模型名（null = 未配置，图标置灰）。
  final String? modelName;

  /// 添加图片 / 选择模型：回调携带**按钮自身的 BuildContext**，
  /// 供浮层锚定在图标上方展开（见 showGlassAnchoredMenu）。
  final void Function(BuildContext anchor) onAddImage;
  final void Function(BuildContext anchor) onPickModel;

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
            // 加号按钮：Builder 包一层拿到按钮自身的 context，
            // 浮层据此锚定在图标上方展开。
            Builder(
              builder: (bctx) => SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  icon: Icon(Icons.add_rounded,
                      size: 24,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  onPressed: () => onAddImage(bctx),
                ),
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
            // 模型选择：麦克风旁的调音图标。浮层锚定在图标上方展开。
            Builder(
              builder: (bctx) => SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip:
                      modelName == null ? '未配置模型' : '当前模型：$modelName',
                  icon: Icon(
                    Icons.tune_rounded,
                    size: 22,
                    color: modelName == null
                        ? onSurface(context, 0.2)
                        : onSurface(context, 0.35),
                  ),
                  onPressed:
                      modelName == null ? null : () => onPickModel(bctx),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
