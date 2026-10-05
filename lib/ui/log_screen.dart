import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../services/app_log.dart';
import '../theme.dart';

/// 诊断日志页（关于 → 日志）：查看 App 存活期内捕获的日志
/// （全局错误 + 关键事件），支持复制全部与导出为文本文件。
///
/// 日志为内存环形缓冲（500 条，App 存活期内有效），导出走系统查看器。
class LogScreen extends ConsumerStatefulWidget {
  const LogScreen({super.key});

  @override
  ConsumerState<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends ConsumerState<LogScreen> {
  // 进入页面时重建列表快照（AppLog 是内存环形缓冲，无流式通知）
  late List<String> _entries = List.of(AppLog.entries);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded, size: 22),
            onPressed: () =>
                setState(() => _entries = List.of(AppLog.entries)),
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: AppLog.asText()));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('日志已复制到剪贴板')));
            },
          ),
          IconButton(
            tooltip: '导出为文件',
            icon: const Icon(Icons.ios_share_rounded, size: 20),
            onPressed: _export,
          ),
        ],
      ),
      body: _entries.isEmpty
          ? Center(
              child: Text('暂无日志',
                  style: TextStyle(
                      fontSize: 14, color: onSurface(context, 0.4))))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _entries.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: onSurface(context, 0.06)),
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SelectableText(
                  _entries[i],
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    fontFamily: 'monospace',
                    color: _entries[i].contains('[E]')
                        ? const Color(0xFFD93025)
                        : onSurface(context, 0.75),
                  ),
                ),
              ),
            ),
    );
  }

  /// 导出到临时目录的文本文件并用系统查看器打开（用户可另存/分享）。
  Future<void> _export() async {
    final path = await AppLog.exportToFile();
    if (!mounted) return;
    if (path == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('导出失败')));
      return;
    }
    AppLog.i('日志已导出: $path');
    setState(() => _entries = List.of(AppLog.entries));
    try {
      await OpenFilex.open(path);
    } catch (_) {}
  }
}
