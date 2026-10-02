import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../services/file_storage_service.dart';

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

  int get _total => _entries?.fold(0, (a, e) => a + e.bytes) ?? 0;
  int get _cacheBytes => _entries
          ?.where((e) => e.label.contains('缓存') || e.label == '临时文件')
          .fold(0, (a, e) => a + e.bytes) ??
      0;

  Future<void> _confirmClear({
    required String title,
    required String message,
    required Future<int> Function() action,
  }) async {
    final ok = await showDialog<bool>(
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
