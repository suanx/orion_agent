import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'glass.dart';
import '../providers/providers.dart';
import '../services/database.dart';

/// MCP 服务器管理：添加 Streamable HTTP 端点，启用/停用，删除。
class McpScreen extends ConsumerStatefulWidget {
  const McpScreen({super.key});

  @override
  ConsumerState<McpScreen> createState() => _McpScreenState();
}

class _McpScreenState extends ConsumerState<McpScreen> {
  List<McpServer>? _servers;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final servers = await ref.read(mcpServiceProvider).listServers();
    if (mounted) setState(() => _servers = servers);
  }

  Future<void> _reloadAndConnect() async {
    setState(() => _connecting = true);
    try {
      final n = await ref.read(mcpServiceProvider).connectAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(n > 0
                ? '已连接，注册了 $n 个 MCP 工具'
                : '没有连接到可用的 MCP 服务器')));
      }
    } finally {
      await _reload();
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// 添加 / 编辑 MCP 服务器共用弹窗。[existing] 非空为编辑模式，
  /// 输入框预填当前值；返回 (name, url) 或 null（取消）。
  Future<(String, String)?> _showServerDialog({
    McpServer? existing,
  }) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl =
        TextEditingController(text: existing?.url ?? 'http://');
    // 双输入框弹窗，不迁移 showGlassTextDialog；输入值随 pop 带出 +
    // whenComplete dispose（P2-6）。
    final saved = await showGlassDialog<(String, String)>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: Text(existing == null ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称（如：文件服务）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: '端点 URL（Streamable HTTP）',
                hintText: 'http://192.168.1.10:3000/mcp',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, (nameCtrl.text.trim(), urlCtrl.text.trim())),
              child: Text(existing == null ? '添加' : '保存')),
        ],
      ),
    ).whenComplete(() {
      nameCtrl.dispose();
      urlCtrl.dispose();
    });
    return saved;
  }

  void _showInvalidTip() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('名称和 URL 不能为空，URL 需以 http 开头')));
  }

  Future<void> _addServer() async {
    final saved = await _showServerDialog();
    if (saved == null) return;
    final name = saved.$1;
    final url = saved.$2;
    if (name.isEmpty || !url.startsWith('http')) {
      _showInvalidTip();
      return;
    }
    await ref.read(mcpServiceProvider).addServer(name, url);
    await _reloadAndConnect();
  }

  /// 编辑既有服务器：改完落库并重连（改名会换工具前缀、改 URL 换端点）。
  Future<void> _editServer(McpServer s) async {
    final saved = await _showServerDialog(existing: s);
    if (saved == null) return;
    final name = saved.$1;
    final url = saved.$2;
    if (name.isEmpty || !url.startsWith('http')) {
      _showInvalidTip();
      return;
    }
    if (name == s.name && url == s.url) return; // 无变化不重连
    await ref.read(mcpServiceProvider).updateServer(s.id, name: name, url: url);
    await _reloadAndConnect();
  }

  @override
  Widget build(BuildContext context) {
    final servers = _servers;

    return Scaffold(
      appBar: AppBar(title: const Text('MCP 服务器')),
      floatingActionButton: _connecting
          ? const FloatingActionButton.extended(
              onPressed: null,
              icon: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              label: Text('连接中…'),
            )
          : FloatingActionButton.extended(
              onPressed: _addServer,
              icon: const Icon(Icons.add),
              label: const Text('添加服务器'),
            ),
      body: servers == null
          ? const Center(child: CircularProgressIndicator())
          : servers.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '还没有 MCP 服务器。\n\n'
                      '添加后，Agent 可以调用外部工具服务。\n'
                      '支持 Streamable HTTP 端点。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: servers.length,
                  itemBuilder: (_, i) {
                    final s = servers[i];
                    return ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(s.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w500)),
                      subtitle: Text(s.url,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: s.enabled,
                            onChanged: (v) async {
                              await ref
                                  .read(mcpServiceProvider)
                                  .setEnabled(s.id, v);
                              await _reload();
                              if (v) await _reloadAndConnect();
                            },
                          ),
                          // 编辑：改名称/URL 后自动断开旧连接并按新配置重连
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            tooltip: '编辑',
                            onPressed: () => _editServer(s),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            // 二次确认（2026-10-11 P1）
                            onPressed: () async {
                              final ok = await confirmDestructive(
                                context,
                                title: '删除 MCP 服务器',
                                message:
                                    '「${s.name}」将被移除，其提供的全部工具不再可用。',
                              );
                              if (!ok) return;
                              await ref
                                  .read(mcpServiceProvider)
                                  .removeServer(s.id);
                              await _reload();
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
