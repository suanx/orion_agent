import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/agent_artifact_service.dart';
import '../services/cloud_service.dart';
import '../theme.dart';
import 'glass.dart';

/// 云端 Agent 沙箱产物页。
///
/// 展示 Agent 干完活留下的东西：改过的文件树 + 文件内容 + dev server 预览。
/// 入口在对话页右上角（仅当当前模型是云端 Agent 时出现）。
///
/// 数据全部走 `/api/agent/*`（后端转发到 orion-forge），App 不直连实例，
/// 因此页面不需要（也不该）关心实例地址与鉴权。
class AgentArtifactScreen extends ConsumerStatefulWidget {
  const AgentArtifactScreen({super.key, required this.appSessionId});

  /// App 自己的会话 id；后端靠它反查远端 Agent 会话。
  final String appSessionId;

  @override
  ConsumerState<AgentArtifactScreen> createState() => _AgentArtifactScreenState();
}

class _AgentArtifactScreenState extends ConsumerState<AgentArtifactScreen> {
  List<AgentFileNode> _files = const [];
  AgentDevServer? _devServer;

  /// 预览中的文件（null = 停在文件列表）。
  AgentFileContent? _preview;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final svc = ref.read(agentArtifactServiceProvider);
    try {
      final files = await svc.listFiles(widget.appSessionId);
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } on CloudException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _openFile(AgentFileNode node) async {
    if (node.isDirectory) return;
    // 预览期间给一层轻量加载态：forge 读文件要连沙箱，可能有 1~2 秒。
    if (mounted) setState(() => _busy = true);
    try {
      final content = await ref
          .read(agentArtifactServiceProvider)
          .readFile(widget.appSessionId, node.cleanPath);
      if (!mounted) return;
      setState(() {
        _preview = content;
        _busy = false;
      });
    } on CloudException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
    }
  }

  void _closePreview() => setState(() => _preview = null);

  Future<void> _toggleDevServer() async {
    final svc = ref.read(agentArtifactServiceProvider);
    final running = _devServer?.isRunning ?? false;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      if (running) {
        await svc.stopDevServer(widget.appSessionId);
        if (!mounted) return;
        setState(() {
          _devServer = null;
          _busy = false;
        });
        _toast('已停止预览服务');
      } else {
        final server = await svc.startDevServer(widget.appSessionId);
        if (!mounted) return;
        setState(() {
          _devServer = server;
          _busy = false;
        });
      }
    } on CloudException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
    }
  }

  void _copyContent() {
    final text = _preview?.content;
    if (text == null || text.isEmpty) {
      _toast('文件为空');
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    _toast('已复制文件内容');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent 产物'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _preview != null ? _buildPreview() : _buildList(),
    );
  }

  // ---- 文件列表 ----

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return _Empty(
        icon: Icons.cloud_off,
        title: '读取失败',
        message: _error!,
        action: TextButton(onPressed: _load, child: const Text('重试')),
      );
    }

    if (_files.isEmpty) {
      return _Empty(
        icon: Icons.folder_open,
        title: '暂无产物',
        message: '先在对话里让 Agent 做点事，它改过的文件会出现在这里。',
        action: TextButton(onPressed: _load, child: const Text('刷新')),
      );
    }

    final files = _files;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _DevServerCard(
          server: _devServer,
          busy: _busy,
          onToggle: _toggleDevServer,
        ),
        const Divider(height: 1),
        for (final node in files) _FileTile(node: node, onTap: () => _openFile(node)),
      ],
    );
  }

  // ---- 文件预览 ----

  Widget _buildPreview() {
    final preview = _preview!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: onSurface(context, 0.9),
                      ),
                    ),
                    Text(
                      preview.readableSize,
                      style: TextStyle(fontSize: 11, color: onSurface(context, 0.45)),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '复制内容',
                onPressed: _copyContent,
                icon: const Icon(Icons.copy_all_outlined, size: 20),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: _closePreview,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: preview.content.isEmpty
              ? const Center(child: Text('（空文件）'))
              : Scrollbar(
                  child: SingleChildScrollView(
                    primary: true,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: SingleChildScrollView(
                      // 横向滚动：代码行往往比屏宽长，强制换行会毁掉缩进结构
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        preview.content,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.5,
                          color: onSurface(context, 0.85),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// dev server 卡片：启停 + 预览地址。
class _DevServerCard extends StatelessWidget {
  const _DevServerCard({
    required this.server,
    required this.busy,
    required this.onToggle,
  });

  final AgentDevServer? server;
  final bool busy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final running = server?.isRunning ?? false;
    return ListTile(
      leading: Icon(
        running ? Icons.play_circle_fill : Icons.play_circle_outline,
        color: running ? Colors.green : onSurface(context, 0.45),
      ),
      title: Text('预览服务${running ? '（运行中 :${server!.port}）' : ''}'),
      subtitle: Text(
        running ? server!.url : '启动后可实时查看 Agent 做出来的页面',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: onSurface(context, 0.45)),
      ),
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: onToggle,
              child: Text(running ? '停止' : '启动'),
            ),
    );
  }
}

/// 文件树里的一项。
class _FileTile extends StatelessWidget {
  const _FileTile({required this.node, required this.onTap});

  final AgentFileNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // forge 已按「顶层优先 + 同层字典序」排好序，直接铺平当列表即可
    final depth = node.isDirectory
        ? node.cleanPath.split('/').length - 1
        : node.path.split('/').length - 1;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.only(left: 16.0 + depth * 14.0, right: 16),
      leading: Icon(
        node.isDirectory ? Icons.folder_rounded : Icons.description_outlined,
        size: 18,
        color: node.isDirectory
            ? Colors.amber.shade700
            : onSurface(context, 0.45),
      ),
      title: Text(
        node.display.split('/').last,
        style: TextStyle(fontSize: 13, color: onSurface(context, 0.85)),
      ),
      onTap: onTap,
    );
  }
}

/// 空态 / 错误态。
class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: onSurface(context, 0.3)),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: onSurface(context, 0.5)),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}