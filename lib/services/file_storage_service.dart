import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一个可清理的存储类别。
class StorageEntry {
  const StorageEntry({
    required this.label,
    required this.path,
    required this.bytes,
    required this.fileCount,
    this.deletable = true,
    this.note,
  });

  final String label;
  final String path;
  final int bytes;
  final int fileCount;

  /// 是否允许清理（终端环境删掉要重装，故不提供一键清理，只做展示）。
  final bool deletable;
  final String? note;

  String get sizeText => formatBytes(bytes);
}

/// 把字节数格式化成易读文本。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// 文件存储管理：统计各目录占用、清理缓存。
///
/// 目录划分与 TerminalService 保持一致：
/// - workspace：Agent 与终端共享的工作区（用户可见、不自动清理）
/// - 终端 rootfs：Alpine / Debian 解压目录（体积大，仅展示）
/// - 缓存：TTS 音频、临时解压文件等（可安全清理）
/// - 数据库与偏好设置：会话/记忆/知识库（在「我的 → 清空会话」处理）
class StorageService {
  /// 递归统计目录大小（软链接不计入，避免死循环）。
  static ({int bytes, int files}) _measure(Directory dir) {
    if (!dir.existsSync()) return (bytes: 0, files: 0);
    var bytes = 0;
    var files = 0;
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            bytes += e.lengthSync();
            files++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return (bytes: bytes, files: files);
  }

  static StorageEntry _entry(String label, Directory dir, {bool deletable = true, String? note}) {
    final m = _measure(dir);
    return StorageEntry(
      label: label,
      path: dir.path,
      bytes: m.bytes,
      fileCount: m.files,
      deletable: deletable,
      note: note,
    );
  }

  /// 工作区目录（与终端 /workspace 同一个）。
  static Future<Directory> workspaceDir() async {
    String base;
    try {
      base = (await getExternalStorageDirectory())?.path ?? '';
    } catch (_) {
      base = '';
    }
    if (base.isEmpty) base = (await getApplicationSupportDirectory()).path;
    return Directory('$base/workspace');
  }

  static Future<Directory> _support() => getApplicationSupportDirectory();
  static Future<Directory> _temp() => getTemporaryDirectory();

  /// 统计全部存储占用。
  static Future<List<StorageEntry>> scan() async {
    final support = await _support();
    final temp = await _temp();
    final ws = await workspaceDir();

    return [
      _entry('工作区', ws,
          note: 'Agent 与终端共享，挂载为 /workspace，系统文件管理器可直接访问'),
      _entry('Alpine 终端环境', Directory('${support.path}/alpine-rootfs'),
          deletable: false, note: '删除后需重新安装'),
      _entry('Debian 终端环境', Directory('${support.path}/debian-rootfs'),
          deletable: false, note: '删除后需重新安装'),
      _entry('TTS 音频缓存', Directory('${temp.path}/tts'),
          note: 'Edge TTS 合成的临时音频，播完即删'),
      _entry('临时文件', temp,
          note: '系统临时目录（含下载过程中的缓存）'),
      _entry('应用数据', support,
          deletable: false, note: '会话数据库、偏好设置等，请用「清空所有会话」处理'),
    ];
  }

  /// 清理缓存类目录（TTS 音频 + 临时目录），返回释放的字节数。
  static Future<int> clearCache() async {
    var freed = 0;
    final temp = await _temp();
    final targets = [
      Directory('${temp.path}/tts'),
      temp,
    ];
    for (final dir in targets) {
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync(followLinks: false)) {
        try {
          final isDir = e is Directory;
          var size = 0;
          if (isDir) {
            size = _measure(e as Directory).bytes;
          } else if (e is File) {
            size = e.lengthSync();
          }
          e.deleteSync(recursive: true);
          freed += size;
        } catch (_) {}
      }
    }
    return freed;
  }

  /// 清空工作区（用户主动触发，需二次确认）。
  static Future<int> clearWorkspace() async {
    final ws = await workspaceDir();
    if (!ws.existsSync()) return 0;
    var freed = _measure(ws).bytes;
    for (final e in ws.listSync(followLinks: false)) {
      try {
        e.deleteSync(recursive: true);
      } catch (_) {}
    }
    return freed;
  }
}
