import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 终端环境支持的发行版。
enum TerminalDistro { alpine, debian }

class DistroSpec {
  final TerminalDistro id;
  final String displayName;
  final String dirName;
  final String downloadUrl;
  final bool isGzip; // alpine: tar.gz；debian: tar.xz

  const DistroSpec({
    required this.id,
    required this.displayName,
    required this.dirName,
    required this.downloadUrl,
    required this.isGzip,
  });
}

class TerminalService {
  TerminalService({Dio? dio}) : _dio = dio ?? Dio();

  static const _channel = MethodChannel('pocket_agent/system');

  static const specs = <TerminalDistro, DistroSpec>{
    TerminalDistro.alpine: DistroSpec(
      id: TerminalDistro.alpine,
      displayName: 'Alpine',
      dirName: 'alpine-rootfs',
      downloadUrl:
          'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.6-aarch64.tar.gz',
      isGzip: true,
    ),
    TerminalDistro.debian: DistroSpec(
      id: TerminalDistro.debian,
      displayName: 'Debian 12',
      dirName: 'debian-rootfs',
      downloadUrl:
          'https://github.com/suanx/pocket-agent/releases/download/terminal-env/debian-bookworm-arm64-rootfs.tar.xz',
      isGzip: false,
    ),
  };

  static const _tuna = 'https://mirrors.tuna.tsinghua.edu.cn';

  /// 各发行版一键安装组件的包管理命令（纯函数，便于测试）。
  static String alpineInstallCommand(List<String> pkgs) =>
      'apk add --no-cache ${pkgs.join(' ')}';

  static String debianInstallCommand(List<String> pkgs) =>
      'apt-get update -qq && apt-get install -y --no-install-recommends ${pkgs.join(' ')}';

  static String installCommandFor(TerminalDistro d, List<String> pkgs) =>
      d == TerminalDistro.alpine
          ? alpineInstallCommand(pkgs)
          : debianInstallCommand(pkgs);

  final Dio _dio;
  String? _nativeLibDir;
  final _rootfsCache = <TerminalDistro, String>{};

  /// 当前激活的发行版（由终端页设置并持久化，Agent 工具使用它）。
  TerminalDistro activeDistro = TerminalDistro.alpine;

  Future<String> get nativeLibDir async {
    if (_nativeLibDir != null) return _nativeLibDir!;
    final dir = await _channel.invokeMethod<String>('nativeLibDir');
    if (dir == null || dir.isEmpty) {
      throw Exception('无法获取 nativeLibraryDir（仅 Android 可用终端环境）');
    }
    return _nativeLibDir = dir;
  }

  Future<String> rootfsDir(TerminalDistro d) async {
    final cached = _rootfsCache[d];
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    return _rootfsCache[d] = '${support.path}/${specs[d]!.dirName}';
  }

  /// 指定发行版是否已安装（busybox/dash 存在即视为完整）。
  Future<bool> isInstalled(TerminalDistro d) async {
    try {
      final rootfs = await rootfsDir(d);
      final marker =
          d == TerminalDistro.alpine ? '$rootfs/bin/busybox' : '$rootfs/usr/bin/apt-get';
      return File(marker).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 下载并解压 rootfs，随后修正执行权限、DNS 与包管理镜像。
  Future<void> install(
    TerminalDistro d, {
    void Function(String progress)? onProgress,
  }) async {
    final spec = specs[d]!;
    final rootfs = await rootfsDir(d);
    final tmp = await getTemporaryDirectory();
    final archivePath = '${tmp.path}/${spec.dirName}.tar';

    void report(String msg) => onProgress?.call(msg);

    report('下载 ${spec.displayName} 基础系统…');
    await _dio.download(spec.downloadUrl, archivePath);

    report('解压 rootfs…');
    final rootfsHandle = Directory(rootfs);
    if (rootfsHandle.existsSync()) rootfsHandle.deleteSync(recursive: true);
    rootfsHandle.createSync(recursive: true);

    final compressed = File(archivePath).readAsBytesSync();
    List<int> tarBytes;
    if (spec.isGzip) {
      tarBytes = GZipDecoder().decodeBytes(compressed);
    } else {
      tarBytes = XZDecoder().decodeBytes(compressed);
    }
    final tar = TarDecoder().decodeBytes(tarBytes);
    for (final entry in tar) {
      final path = '$rootfs/${entry.name}';
      if (entry.isSymbolicLink) {
        String target;
        try {
          target = utf8.decode(entry.content as List<int>);
        } catch (_) {
          continue;
        }
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
    File(archivePath).deleteSync();

    report('修正执行权限…');
    // rootfs 内二进制需要 exec 位；dart:io 无 chmod，借用系统 toybox
    await Process.run('/system/bin/chmod', ['-R', '755', rootfs]);

    report('配置 DNS 与镜像…');
    await _postConfigure(d, rootfs);

    report('完成');
  }

  Future<void> _postConfigure(TerminalDistro d, String rootfs) async {
    if (d == TerminalDistro.alpine) {
      File('$rootfs/etc/resolv.conf')
          .writeAsStringSync('nameserver 223.5.5.5\nnameserver 119.29.29.29\n');
      File('$rootfs/etc/apk/repositories').writeAsStringSync(
          '$_tuna/alpine/v3.22/main\n$_tuna/alpine/v3.22/community\n');
    } else {
      File('$rootfs/etc/resolv.conf')
          .writeAsStringSync('nameserver 223.5.5.5\nnameserver 119.29.29.29\n');
      // bookworm-slim 用 deb822 格式的 debian.sources，清掉换成传统 sources.list
      final debSources = File('$rootfs/etc/apt/sources.list.d/debian.sources');
      if (debSources.existsSync()) debSources.deleteSync();
      File('$rootfs/etc/apt/sources.list').writeAsStringSync(
          'deb http://$_tuna/debian bookworm main contrib non-free non-free-firmware\n'
          'deb http://$_tuna/debian bookworm-updates main contrib non-free non-free-firmware\n'
          'deb http://$_tuna/debian-security bookworm-security main contrib non-free non-free-firmware\n');
    }
  }

  /// 在当前激活的发行版内执行一条 shell 命令。
  Future<TerminalResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) {
    return runOn(activeDistro, command, timeout: timeout);
  }

  Future<TerminalResult> runOn(
    TerminalDistro d,
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final proc = await startOn(d, command);
    final buf = StringBuffer();
    final sub1 =
        proc.stdout.cast<List<int>>().transform(utf8.decoder).listen(buf.write);
    final sub2 =
        proc.stderr.cast<List<int>>().transform(utf8.decoder).listen(buf.write);
    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill();
      return -1;
    });
    await sub1.asFuture<void>();
    await sub2.asFuture<void>();
    return TerminalResult(exitCode: code, output: buf.toString());
  }

  /// 启动一个 proot 会话进程（供流式读取）。
  Future<Process> startOn(TerminalDistro d, String command) async {
    final rootfs = await rootfsDir(d);
    final libDir = await nativeLibDir;
    final tmp = await getTemporaryDirectory();
    final shell = d == TerminalDistro.alpine ? '/bin/sh' : '/bin/bash';
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
        shell, '-c', command,
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

  /// 删除指定发行版的环境。
  Future<void> uninstall(TerminalDistro d) async {
    final dir = Directory(await rootfsDir(d));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

class TerminalResult {
  final int exitCode;
  final String output;

  const TerminalResult({required this.exitCode, required this.output});

  bool get ok => exitCode == 0;

  /// 取输出中首个非空行（如 node --version 的结果）。
  String? get versionLine {
    for (final line in output.trim().split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      return l.length > 60 ? '${l.substring(0, 60)}…' : l;
    }
    return null;
  }
}
