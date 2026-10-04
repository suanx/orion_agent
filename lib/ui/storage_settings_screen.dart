import 'dart:io';

import '../theme.dart';
import 'glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/file_storage_service.dart';
import '../services/workspace_store.dart';

/// 存储设置：各目录占用统计、清理缓存、清空工作区。
class StorageSettingsScreen extends ConsumerStatefulWidget {
  const StorageSettingsScreen({super.key});

  @override
  ConsumerState<StorageSettingsScreen> createState() =>
      _StorageSettingsScreenState();
}

class _StorageSettingsScreenState
    extends ConsumerState<StorageSettingsScreen> {
  List<StorageEntry>? _entries;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final list = await FileStorageService.scan();
    if (mounted) setState(() => _entries = list);
  }

  int get _total {
    final list = _entries;
    if (list == null) return 0;
    var sum = 0;
    for (final e in list) {
      sum += e.bytes;
    }
    return sum;
  }

  /// 可清理部分的大小。
  ///
  /// 「TTS 音频缓存」目录位于「临时文件」目录之内，两者都匹配时会重复计数，
  /// 这里按路径前缀去重：被其他条目包含的目录不再单独累加。
  int get _cacheBytes {
    final list = _entries;
    if (list == null) return 0;
    final cache = list
        .where((e) => e.label.contains('缓存') || e.label == '临时文件')
        .toList();
    var sum = 0;
    for (final e in cache) {
      final nested =
          cache.any((o) => o != e && o.path.isNotEmpty && e.path.startsWith(o.path));
      if (!nested) sum += e.bytes;
    }
    return sum;
  }

  Future<void> _confirmClear({
    required String title,
    required String message,
    required Future<int> Function() action,
  }) async {
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清理',
                  style: TextStyle(color: Color(0xFFD93025)))),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final freed = await action();
    await _scan();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(freed == 0
            ? '没有需要清理的内容'
            : '已释放 ${formatBytes(freed)}')));
  }

  Future<void> _openDir(String path) async {
    try {
      final r = await OpenFilex.open(path);
      if (r.type != ResultType.done) {
        throw Exception(r.message);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开文件管理器，可手动前往该路径')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('存储'),
        actions: [
          IconButton(
            tooltip: '重新统计',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _busy ? null : _scan,
          ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                // ------- 总览 -------
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: surface(context),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('已占用',
                          style: TextStyle(
                              fontSize: 13, color: onSurface(context, 0.45))),
                      const SizedBox(height: 6),
                      Text(formatBytes(_total),
                          style: const TextStyle(
                              fontSize: 28, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 4),
                      Text('其中缓存约 ${formatBytes(_cacheBytes)}',
                          style: TextStyle(
                              fontSize: 12, color: onSurface(context, 0.4))),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // ------- 工作区目录 -------
                _label('工作区'),
                const _WorkspaceDirCard(),
                const SizedBox(height: 20),

                // ------- 明细 -------
                _label('目录明细'),
                ...entries.map(_entryTile),
                const SizedBox(height: 20),

                // ------- 清理 -------
                _label('清理'),
                _card([
                  ListTile(
                    leading: const Icon(Icons.cleaning_services_rounded, size: 20),
                    title: const Text('清理缓存',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    subtitle: Text('TTS 音频与临时文件，可安全清理',
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.4))),
                    trailing: Text(formatBytes(_cacheBytes),
                        style: TextStyle(
                            fontSize: 13, color: onSurface(context, 0.4))),
                    onTap: _busy
                        ? null
                        : () => _confirmClear(
                              title: '清理缓存？',
                              message: '将删除 TTS 音频缓存与临时目录内容，'
                                  '不影响会话、记忆与知识库。',
                              action: FileStorageService.clearCache,
                            ),
                  ),
                  Divider(height: 1, color: onSurface(context, 0.06)),
                  ListTile(
                    leading: const Icon(Icons.folder_delete_outlined, size: 20),
                    title: const Text('清空工作区',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    subtitle: Text('删除 /workspace 下的全部文件，不可恢复',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFFD93025))),
                    onTap: _busy
                        ? null
                        : () => _confirmClear(
                              title: '清空工作区？',
                              message: '将删除 /workspace 下的所有文件，'
                                  '包括 Agent 生成和终端创建的产物。此操作不可恢复。',
                              action: FileStorageService.clearWorkspace,
                            ),
                  ),
                ]),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '终端环境（Alpine/Debian）占用较大且删除后需重装，'
                    '因此只展示不提供一键清理，可在「我的 → 终端环境」里卸载。',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: onSurface(context, 0.4)),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _entryTile(StorageEntry e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDir(e.path),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(e.label,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                  ),
                  Text(e.sizeText,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: e.bytes > 0
                              ? onSurface(context, 0.85)
                              : onSurface(context, 0.3))),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.folder_outlined,
                      size: 12, color: onSurface(context, 0.3)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${e.fileCount} 个文件 · ${e.path}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: onSurface(context, 0.35)),
                    ),
                  ),
                ],
              ),
              if (e.note != null) ...[
                const SizedBox(height: 6),
                Text(e.note!,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: onSurface(context, 0.45))),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
        child: Text(t,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: onSurface(context, 0.45))),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: surface(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(children: children),
      );
}

/// 工作区目录卡片：展示当前目录，支持更换为自定义目录。
///
/// 工作区是 Agent 产物与终端 `/workspace` 挂载的共享目录。
/// 默认在外部存储的应用专属目录下；选择自定义目录后立即生效
/// （WorkspaceStore 每次解析都读最新设置，无缓存延迟）。
class _WorkspaceDirCard extends StatefulWidget {
  const _WorkspaceDirCard();

  @override
  State<_WorkspaceDirCard> createState() => _WorkspaceDirCardState();
}

class _WorkspaceDirCardState extends State<_WorkspaceDirCard> {
  String? _current;
  String? _default;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final cur = await WorkspaceStore.path();
    final def = await WorkspaceStore.defaultPath();
    if (mounted) {
      setState(() {
        _current = cur;
        _default = def;
      });
    }
  }

  bool get _isCustom =>
      _current != null && _default != null && _current != _default;

  Future<void> _pick() async {
    final prefs = await SharedPreferences.getInstance();
    final controller =
        TextEditingController(text: prefs.getString(WorkspaceStore.prefsKey) ?? '');

    // 扫描公共存储的一级目录作为快捷选项；无权限或路径不存在时
    // 静默降级为纯手动输入。
    final roots = <String>[];
    try {
      final base = Directory('/storage/emulated/0');
      if (base.existsSync()) {
        await for (final e in base.list(followLinks: false)) {
          if (e is Directory) roots.add(e.path);
        }
        roots.sort();
      }
    } catch (_) {}

    if (!mounted) return;
    final sel = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择工作区目录'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('Agent 产物与终端 /workspace 将使用该目录。',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: onSurface(ctx, 0.45))),
              const SizedBox(height: 8),
              for (final r in roots)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text(r,
                      style: const TextStyle(fontSize: 13)),
                  onTap: () => Navigator.pop(ctx, r),
                ),
              if (roots.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Divider(
                      height: 1, color: onSurface(ctx, 0.08)),
                ),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '或手动输入完整路径',
                  hintText: '/storage/emulated/0/...',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('使用输入路径'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
        ],
      ),
    // 手动输入路径的 TextField 控制器由本方法创建（P2-6）：
    // 值都随 pop 带出，弹窗关闭后统一 dispose。
    ).whenComplete(controller.dispose);
    if (sel == null) return;
    if (sel.isEmpty) {
      await prefs.remove(WorkspaceStore.prefsKey);
    } else {
      // 目录不可创建时 WorkspaceStore.path() 会自动回退默认，
      // 这里不做二次校验，选完刷新展示真实生效路径即可。
      await prefs.setString(WorkspaceStore.prefsKey, sel);
    }
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('工作区目录已更新，下一次执行时生效')));
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('工作区目录',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500)),
              ),
              TextButton(
                onPressed: _pick,
                child: const Text('更改目录'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 12, color: onSurface(context, 0.3)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  cur ?? '读取中…',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: onSurface(context, 0.35)),
                ),
              ),
            ],
          ),
          if (_isCustom) ...[
            const SizedBox(height: 6),
            Text('已使用自定义目录，恢复默认回到应用专属目录。',
                style: TextStyle(
                    fontSize: 12, color: onSurface(context, 0.45))),
          ],
        ],
      ),
    );
  }
}
