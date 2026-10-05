import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 轻量诊断日志：内存环形缓冲 + 可选导出为文本文件。
///
/// 不落盘（App 存活期内有效）——崩溃前的关键错误由 main.dart 的全局
/// 错误钩子写入这里，用户在「关于 → 日志」页查看并导出。
/// 约定：不要把 API Key / 消息正文打进日志，只记录事件与错误摘要。
class AppLog {
  AppLog._();

  static const _maxEntries = 500;
  static final List<String> _entries = <String>[];

  static Iterable<String> get entries => List.unmodifiable(_entries);

  static void _add(String level, String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23); // HH:mm:ss.SSS
    _entries.add('[$ts][$level] $msg');
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
  }

  static void i(String msg) => _add('I', msg);
  static void w(String msg) => _add('W', msg);
  static void e(String msg, [Object? error]) =>
      _add('E', error == null ? msg : '$msg :: $error');

  /// 导出为文本文件（temp 目录），返回文件路径；失败返回 null。
  static Future<String?> exportToFile() async {
    try {
      final tmp = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .substring(0, 15);
      final f = File('${tmp.path}/orion_log_$ts.txt');
      await f.writeAsString(
          _entries.isEmpty ? '（无日志）' : _entries.join('\n'),
          flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// 全部日志拼成一段文本（复制到剪贴板用）。
  static String asText() =>
      _entries.isEmpty ? '（无日志）' : _entries.join('\n');
}
