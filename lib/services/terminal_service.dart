import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 终端环境：proot + Alpine rootfs，免 root 的 Linux 命令执行环境。
///
/// - proot 二进制在 CI 打包进 APK 的 jniLibs（libproot.so），运行时位于
///   nativeLibraryDir，是唯一由内核直接 exec 的宿主二进制；
/// - Alpine minirootfs（约 4MB）首次使用时从清华镜像下载并解压到应用目录；
/// - guest 内的二进制经 proot 执行，依赖 targetSdk 28 保留数据目录 exec 权限。
class TerminalService {
  TerminalService({Dio? dio}) : _dio = dio ?? Dio();

  static const _channel = MethodChannel('pocket_agent/system');

  static const minirootfsUrl =
      'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.6-aarch64.tar.gz';
  static const alpineMainMirror =
      'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22/main';
  static const alpineCommunityMirror =
      'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22/community';

  final Dio _dio;
  String? _nativeLibDir;
  String? _rootfsDir;

  Future<String> get nativeLibDir async {
    if (_nativeLibDir != null) return _nativeLibDir!;
    final dir = await _channel.invokeMethod<String>('nativeLibDir');
    if (dir == null || dir.isEmpty) {
      throw Exception('无法获取 nativeLibraryDir（仅 Android 可用终端环境）');
    }
    return _nativeLibDir = dir;
  }

  Future<String> get rootfsDir async {
    if (_rootfsDir != null) return _rootfsDir!;
    final dir = await getApplicationSupportDirectory();
    return _rootfsDir = '${dir.path}/alpine-rootfs';
  }

  /// 环境是否已安装（busybox 存在即视为完整）。
  Future<bool> isInstalled() async {
    try {
      return File('${await rootfsDir}/bin/busybox').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 下载并解压 Alpine minirootfs，随后修正执行权限、DNS 与 apk 镜像。
  Future<void> install({void Function(String progress)? onProgress}) async {
    final rootfs = await rootfsDir;
    final tmp = await getTemporaryDirectory();
    final tarPath = '${tmp.path}/alpine-minirootfs.tar.gz';

    void report(String msg) => onProgress?.call(msg);

    report('下载 Alpine 基础系统…');
    await _dio.download(minirootfsUrl, tarPath);

    report('解压 rootfs…');
    final rootfsDirHandle = Directory(rootfs);
    if (rootfsDirHandle.existsSync()) {
      rootfsDirHandle.deleteSync(recursive: true);
    }
    rootfsDirHandle.createSync(recursive: true);
    final gzipBytes = File(tarPath).readAsBytesSync();
    final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(gzipBytes));
    for (final entry in tar) {
      final path = '$rootfs/${entry.name}';
      if (entry.isSymbolicLink) {
        final target = entry.symbolicLink ?? '';
        final link = Link(path);
        if (!link.existsSync()) link.create(target);
      } else if (entry.isFile) {
        final f = File(path);
        f.createSync(recursive: true);
        f.writeAsBytesSync(entry.content as List<int>);
      } else {
        Directory(path).createSync(recursive: true);
      }
    }
    File(tarPath).deleteSync();

    report('修正执行权限…');
    // rootfs 内二进制需要 exec 位；dart:io 无 chmod，借用系统 toybox
    await Process.run('/system/bin/chmod', ['-R', '755', rootfs]);

    report('配置 DNS 与 apk 镜像…');
    File('$rootfs/etc/resolv.conf').writeAsStringSync(
        'nameserver 223.5.5.5\nnameserver 119.29.29.29\n');
    File('$rootfs/etc/apk/repositories').writeAsStringSync(
        '$alpineMainMirror\n$alpineCommunityMirror\n');

    report('完成');
  }

  /// 在环境内执行一条 shell 命令，返回输出（stdout+stderr 合并）与退出码。
  Future<TerminalResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final proc = await start(command);
    final buf = StringBuffer();
    final sub1 = proc.stdout.transform(systemEncoding).listen(buf.write);
    final sub2 = proc.stderr.transform(systemEncoding).listen(buf.write);
    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill();
      return -1;
    });
    await sub1.asFuture<void>();
    await sub2.asFuture<void>();
    return TerminalResult(exitCode: code, output: buf.toString());
  }

  /// 启动一个 proot 会话进程（供流式读取）。
  Future<Process> start(String command) async {
    final rootfs = await rootfsDir;
    final libDir = await nativeLibDir;
    final tmp = await getTemporaryDirectory();
    return Process.start(
      '$libDir/libproot.so',
      [
        '-r', rootfs,
        '-0',
        '-w', '/root',
        '--link2symlink',
        '-b', '/dev',
        '-b', '/proc',
        '-b', '/sys',
        '/bin/sh', '-c', command,
      ],
      environment: {
        'PROOT_TMP_DIR': tmp.path,
        'PROOT_NO_SECCOMP': '1',
        'HOME': '/root',
        'TMPDIR': '/tmp',
        'PATH':
            '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'LANG': 'C.UTF-8',
      },
    );
  }

  /// 删除已安装的环境。
  Future<void> uninstall() async {
    final rootfs = await rootfsDir;
    final dir = Directory(rootfs);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

class TerminalResult {
  final int exitCode;
  final String output;

  const TerminalResult({required this.exitCode, required this.output});

  bool get ok => exitCode == 0;

  /// 取输出中第一行含版本号样式的行（如 node --version 的结果）。
  String? get versionLine {
    for (final line in output.trim().split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      return l.length > 60 ? '${l.substring(0, 60)}…' : l;
    }
    return null;
  }
}
