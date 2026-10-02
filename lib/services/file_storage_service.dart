import 'dart:io';

import 'package:flutter/foundation.dart';
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
/// 命名与 `services/storage_service.dart` 的 StorageService（会话库）区分，
/// 避免同名类被同一文件导入时冲突。
///
/// 目录划分与 TerminalService 保持一致：
/// - workspace：Agent 与终端共享的工作区（用户可见、不自动清理）
/// - 终端 rootfs：Alpine / Debian 解压目录（体积大，仅展示）
/// - 缓存：TTS 音频、临时解压文件等（可安全清理）
/// - 数据库与偏好设置：会话/记忆/知识库（在「我的 → 清空会话」处理）
class FileStorageService {
  /// 递归统计目录大小（软链接不计入，避免死循环）。
  ///
  /// 必须在后台 isolate 上跑（见 [_measureAsync]）。这里全是同步 IO，
  /// 而 alpine/debian-rootfs 是解压后的完整发行版（数万文件、几百 MB），
  /// 在 UI isolate 上同步遍历会让主线程卡死数秒到数十秒，直接触发 ANR。
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

  /// 把统计放到后台 isolate，避免阻塞 UI。
  static Future<({int bytes, int files})> _measureAsync(Directory dir) =>
      compute(_measureIsolate, dir.path);

  /// compute 入口：必须是顶层函数或静态方法，且参数可跨isolate 传递。
  static ({int bytes, int files}) _measureIsolate(String path) =>
      _measure(Directory(path));

  static StorageEntry _entry(
    String label,
    Directory dir,
    int bytes,
    int files, {
    bool deletable = true,
    String? note,
  }) {
    return StorageEntry(
      label: label,
      path: dir.path,
      bytes: bytes,
      fileCount: files,
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
  ///
  /// 各类别的统计范围必须【互斥】，否则同一批文件会被计入多个条目，
  /// 展示的占用与合计明显虚高：
  /// - temp/tts 是 temp 的子目录 → 「临时文件」必须减去它
  /// - alpine-rootfs / debian-rootfs 是 support 的子目录 → 「应用数据」必须减去它们
  static Future<List<StorageEntry>> scan() async {
    final support = await _support();
    final temp = await _temp();
    final ws = await workspaceDir();

    final alpineDir = Directory('${support.path}/alpine-rootfs');
    final debianDir = Directory('${support.path}/debian-rootfs');
    final ttsDir = Directory('${temp.path}/tts');

    // 全部在后台 isolate 上并行统计，同一批文件只扫一次
    final results = await Future.wait([
      _measureAsync(ws),
      _measureAsync(alpineDir),
      _measureAsync(debianDir),
      _measureAsync(ttsDir),
      _measureAsync(temp),
      _measureAsync(support),
    ]);
    final wsM = results[0], alpineM = results[1], debianM = results[2];
    final ttsM = results[3], tempM = results[4], supportM = results[5];

    final rootfsBytes = alpineM.bytes + debianM.bytes;
    final rootfsFiles = alpineM.files + debianM.files;

    return [
      _entry('工作区', ws, wsM.bytes, wsM.files,
          note: 'Agent 与终端共享，挂载为 /workspace，系统文件管理器可直接访问'),
      _entry('Alpine 终端环境', alpineDir, alpineM.bytes, alpineM.files,
          deletable: false, note: '删除后需重新安装'),
      _entry('Debian 终端环境', debianDir, debianM.bytes, debianM.files,
          deletable: false, note: '删除后需重新安装'),
      _entry('TTS 音频缓存', ttsDir, ttsM.bytes, ttsM.files,
          note: 'Edge TTS 合成的临时音频，播完即删'),
      // 减去 tts，避免与上一行重复计数
      _entry('临时文件', temp,
          (tempM.bytes - ttsM.bytes).clamp(0, 1 << 62),
          (tempM.files - ttsM.files).clamp(0, 1 << 31),
          note: '系统临时目录（不含 TTS 音频缓存）'),
      // 减去两个 rootfs，避免与上面两行重复计数
      _entry('应用数据', support,
          (supportM.bytes - rootfsBytes).clamp(0, 1 << 62),
          (supportM.files - rootfsFiles).clamp(0, 1 << 31),
          deletable: false,
          note: '会话数据库、偏好设置等（不含终端环境），请用「清空所有会话」处理'),
    ];
  }

  /// 可安全清理的缓存子目录白名单。
  ///
  /// 不能无差别清空整个 temp：终端环境安装过程中，下载/解压的临时文件也在
  /// temp 下，用户在安装过程中点「清理缓存」会把进行中的安装破坏掉。
  static const _cacheWhitelist = {'tts'};

  /// 清理缓存类目录（仅白名单子目录），返回释放的字节数。
  static Future<int> clearCache() async {
    var freed = 0;
    final temp = await _temp();
    if (!temp.existsSync()) return 0;
    for (final e in temp.listSync(followLinks: false)) {
      // 不能用 pathSegments.lastOrNull：实测 pathSegments 会保留结尾的空串
      // （'file:///a/b/c/' → [a, b, c, '']），lastOrNull 会返回空串而非目录名，
      // 白名单永远匹配不上。这里过滤掉空段再取最后一个。
      final segs = e.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty) continue;
      final name = segs.last;
      if (!_cacheWhitelist.contains(name)) continue;
      try {
        final entity = e;
        var size = 0;
        if (entity is Directory) {
          size = _measure(entity).bytes;
        } else if (entity is File) {
          size = entity.lengthSync();
        }
        entity.deleteSync(recursive: true);
        freed += size;
      } catch (_) {}
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
