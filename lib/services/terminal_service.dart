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

  /// 与原生层的通道。
  ///
  /// 目前**没有调用方**了：原先用它取 `nativeLibraryDir` 来执行 proot，
  /// 但那条路走不通（Android 15+ 不再把 native 库解压到磁盘，
  /// 详见 [prootPath] 的注释），改成从 asset 复制到 appSupport。
  ///
  /// 保留通道与 MainActivity.kt 是有意的：后续要拿设备信息
  /// （型号、Android 版本、abi）或做原生能力时可以直接用，
  /// 省得再改 CI 的注入。真的不再需要时，删掉本常量与
  /// ci/MainActivity.kt 里的 MethodChannel 即可。
  static const _channel = MethodChannel('orion_agent/system');

  /// 自启动任务在 shared_preferences 中的存储键。
  static const tasksPrefsKey = 'terminal_tasks';

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
      // 备用源（国内 Docker 镜像不可用时才走这里）。国内镜像优先，
      // 见 install() 里_downloadDebianFromMirror 的优先级。
      downloadUrl:
          'https://github.com/suanx/orion_agent/releases/download/terminal-env/debian-bookworm-arm64-rootfs.tar.xz',
      isGzip: false,
    ),
  };

  /// 安全取发行版配置：漏配时回退为可读占位，避免 UI 侧 `specs[d]!` 直接崩。
  static DistroSpec specOf(TerminalDistro d) =>
      specs[d] ??
      DistroSpec(
        id: d,
        displayName: d.name,
        dirName: '${d.name}-rootfs',
        downloadUrl: '',
        isGzip: true,
      );

  static const _tuna = 'https://mirrors.tuna.tsinghua.edu.cn';

  /// 组件全集（打叉的 agent CLI——codex/Claude Code/DeepSeek/Kimi——不装）。
  static const alpinePackages = [
    'nodejs', 'npm', 'git', 'python3', 'py3-pip', 'uv', 'openssh', 'sshpass',
  ];
  static const debianPackages = [
    'nodejs', 'npm', 'git', 'python3', 'python3-pip',
    'openssh-client', 'openssh-server', 'sshpass', 'ca-certificates', 'curl',
  ];

  static const npmMirror = 'https://registry.npmmirror.com';

  /// 一键安装脚本：系统包 + uv(Debian 走 pip) + OpenCode(npm，走国内镜像)。
  static String alpineInstallScript() =>
      'apk add --no-cache ${alpinePackages.join(' ')} && '
      'npm config set -g registry $npmMirror && '
      'npm install -g opencode-ai';

  static String debianInstallScript() =>
      'apt-get update -qq && '
      'apt-get install -y --no-install-recommends ${debianPackages.join(' ')} && '
      'pip3 install --break-system-packages uv && '
      'npm config set -g registry $npmMirror && '
      'npm install -g opencode-ai';

  static String installScriptFor(TerminalDistro d) =>
      d == TerminalDistro.alpine
          ? alpineInstallScript()
          : debianInstallScript();

  final Dio _dio;
  String? _prootPath;
  final _rootfsCache = <TerminalDistro, String>{};
  String? _workspaceDir;
  final _runningTasks = <String, Process>{};

  /// 当前激活的发行版（由终端页设置并持久化，Agent 工具使用它）。
  TerminalDistro activeDistro = TerminalDistro.alpine;

  // ---------------- Workspace 挂载 ----------------

  /// 宿主侧工作区目录：应用外部存储目录（无需权限，系统文件管理器可见），
  /// 在 guest 内固定挂载为 /workspace。
  Future<String> workspaceDir() async {
    if (_workspaceDir != null) return _workspaceDir!;
    String base;
    try {
      base = (await getExternalStorageDirectory())?.path ?? '';
    } catch (_) {
      base = '';
    }
    base = base.isEmpty ? (await getApplicationSupportDirectory()).path : base;
    final ws = Directory('$base/workspace');
    try {
      if (!ws.existsSync()) ws.createSync(recursive: true);
    } catch (_) {}
    return _workspaceDir = ws.path;
  }

  // ---------------- 自启动任务 ----------------

  /// 启动一个常驻任务（同一名字重复调用会忽略）。
  Future<void> startTask(TerminalTask task) async {
    if (_runningTasks.containsKey(task.name)) return;
    final proc =
        await startOn(task.distro, '${task.command} 2>&1');
    _runningTasks[task.name] = proc;
    unawaited(proc.exitCode
        .whenComplete(() => _runningTasks.remove(task.name)));
  }

  void stopTask(String name) {
    _runningTasks[name]?.kill();
  }

  bool isTaskRunning(String name) => _runningTasks.containsKey(name);

  /// App 启动时拉起所有已启用且环境就绪的任务（由 main 调用，不阻塞启动）。
  Future<void> autostartTasks(List<TerminalTask> tasks) async {
    for (final t in tasks) {
      if (!t.enabled) continue;
      try {
        if (!await isInstalled(t.distro)) continue;
        await startTask(t);
      } catch (_) {
        // 单个任务失败不影响其它
      }
    }
  }

  /// proot 可执行文件的**实际可执行路径**。
  ///
  /// ⚠️ 两个坑（都踩过）：
  ///
  /// 1. **不能从 nativeLibraryDir 取**。
  ///    把 proot 改名成 libproot.so 放进 jniLibs 是行不通的：Android 会
  ///    把它当共享库处理，而且从 Android 15 起native 库直接由 APK 映射
  ///    加载、**不再解压到磁盘**。运行时 exec /libproot.so
  ///    会得到 （表现为「环境装好了但所有组件
  ///    都 lost」，而 rootfs 本身没问题）。
  ///
  /// 2. **不能直接 exec APK 内的 asset**。
  ///    Asset 随包只读，没有执行位。
  ///
  /// 正确做法：从 asset 读出字节 → 写到 appSupport 下的可执行目录 →
  /// chmod +x。复制按「asset 字节数」判断是否需要重做。
  Future<String> prootPath() async {
    if (_prootPath != null) return _prootPath!;
    final support = await getApplicationSupportDirectory();
    final binDir = Directory('${support.path}/bin');
    if (!binDir.existsSync()) {
      binDir.createSync(recursive: true);
    }

    // proot 依赖 libtalloc，必须一起搬，否则启动时报
    // libtalloc.so.2: cannot open shared object file
    const libs = <String, String>{
      'proot': 'assets/proot',
      'libtalloc.so': 'assets/libtalloc.so',
    };

    for (final entry in libs.entries) {
      final name = entry.key;
      final assetPath = entry.value;
      final target = File('${binDir.path}/$name');

      ByteData? data;
      try {
        data = await rootBundle.load(assetPath);
      } catch (_) {
        if (name == 'proot') {
          throw Exception(
              '安装包内缺少终端运行库（$assetPath）。'
              '当前设备可能不是 arm64，或该APK 构建时未注入 proot。');
        }
        continue; // libtalloc 缺失不阻断，由运行时错误暴露
      }
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (bytes.isEmpty) {
        if (name == 'proot') {
          throw Exception('终端运行库（$assetPath）为空，构建产物不完整。');
        }
        continue;
      }

      // 大小一致则跳过重写（asset 是只读的，内容不会变）
      if (!await _sameSize(target, bytes.length)) {
        await target.writeAsBytes(bytes, flush: true);
      }
      // chmod 必须在写入之后：新文件继承 umask，不一定有执行位。
      //
      // 用 /system/bin/chmod 绝对路径：Android 上 app 进程的 PATH 通常
      // 不含 /system/bin，`Process.run('chmod', ...)` 会抛 ProcessException
      // 而不是返回非 0退出码。
      final res = await Process.run(
          '/system/bin/chmod', ['755', target.path]);
      if (res.exitCode != 0) {
        throw Exception('无法为 $name 设置执行权限：${res.stderr}');
      }
    }

    // ⚠️ 必须在循环【外】赋值。
    // 循环里每轮都写 _prootPath 的话，最终值是字典里最后一个键
    // （libtalloc.so）的路径，startOn 拿它去 exec 会失败——
    // 共享库不是可执行文件。
    return _prootPath = '${binDir.path}/proot';
  }

  /// 目标文件是否已是期望大小（避免每次启动都重写几十 MB）。
  Future<bool> _sameSize(File f, int expected) async {
    if (!f.existsSync()) return false;
    try {
      return (await f.stat()).size == expected;
    } catch (_) {
      return false;
    }
  }

  Future<String> rootfsDir(TerminalDistro d) async {
    final cached = _rootfsCache[d];
    if (cached != null) return cached;
    // specs 目前覆盖全部枚举值，但新增发行版而漏改 specs 时 `!` 会直接崩；
    // 这里显式校验并给出可读错误。
    final spec = specs[d];
    if (spec == null) {
      throw Exception('终端环境未配置：${d.name}');
    }
    final support = await getApplicationSupportDirectory();
    return _rootfsCache[d] = '${support.path}/${spec.dirName}';
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
  /// 下载全部走国内：Alpine 用清华镜像；Debian 依次尝试国内 Docker 镜像代理，
  /// 全部失败时才回退到 GitHub 发布页。
  Future<void> install(
    TerminalDistro d, {
    void Function(String progress)? onProgress,
  }) async {
    final spec = specOf(d);
    if (spec.downloadUrl.isEmpty) {
      throw Exception('终端环境未配置下载地址：${d.name}');
    }
    final rootfs = await rootfsDir(d);
    final tmp = await getTemporaryDirectory();
    final archivePath = '${tmp.path}/${spec.dirName}.tar';

    void report(String msg) => onProgress?.call(msg);

    var isGz = spec.isGzip;
    report('下载 ${spec.displayName} 基础系统…');
    if (d == TerminalDistro.debian) {
      var mirrorOk = false;
      try {
        await _downloadDebianFromMirror(report, archivePath);
        isGz = true;
        mirrorOk = true;
      } catch (e) {
        report('国内镜像不可用，改用备用源下载…');
      }
      if (!mirrorOk) {
        await _dio.download(spec.downloadUrl, archivePath);
        isGz = false;
      }
    } else {
      await _dio.download(spec.downloadUrl, archivePath);
    }

    report('解压 rootfs…');
    final rootfsHandle = Directory(rootfs);
    if (rootfsHandle.existsSync()) rootfsHandle.deleteSync(recursive: true);
    rootfsHandle.createSync(recursive: true);

    final compressed = File(archivePath).readAsBytesSync();
    List<int> tarBytes;
    if (isGz) {
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

  // ---------------- 国内镜像拉取（Debian） ----------------

  /// 国内可匿名拉取的 Docker Registry 代理（依次尝试）。
  static const dockerMirrors = <String>[
    'https://docker.m.daocloud.io',
    'https://docker.1ms.run',
    'https://dockerproxy.net',
  ];

  Future<void> _downloadDebianFromMirror(
      void Function(String) report, String savePath) async {
    Object? lastError;
    for (final base in dockerMirrors) {
      try {
        report('尝试镜像 $base …');
        await _pullDockerLayer(base, savePath);
        report('镜像下载完成');
        return;
      } catch (e) {
        lastError = e;
        report('镜像不可用（${e.toString().replaceFirst('Exception: ', '')}）');
      }
    }
    throw Exception('全部国内镜像拉取失败：$lastError');
  }

  /// Docker Registry v2 匿名拉取 library/debian:bookworm-slim 的根层。
  Future<void> _pullDockerLayer(String base, String savePath) async {
    const manifestAccept = 'application/vnd.docker.distribution.manifest.v2+json,'
        'application/vnd.oci.image.manifest.v1+json';

    // ping，取认证方式（有则匿名换 token）
    final ping = await _dio.get<dynamic>('$base/v2/',
        options: Options(
            validateStatus: (s) => s != null && s < 500,
            responseType: ResponseType.plain));
    String? token;
    final www = ping.headers.value('www-authenticate') ?? '';
    final realm = RegExp('realm="([^"]+)"').firstMatch(www)?.group(1);
    if (realm != null) {
      final service = RegExp('service="([^"]+)"').firstMatch(www)?.group(1) ??
          'registry.docker.io';
      final tr = await _dio.get<Map<String, dynamic>>(realm, queryParameters: {
        'service': service,
        'scope': 'repository:library/debian:pull',
      });
      token = (tr.data?['token'] ?? tr.data?['access_token']) as String?;
    }

    // manifest → 根层 digest
    final manifest = await _dio.get<Map<String, dynamic>>(
      '$base/v2/library/debian/manifests/bookworm-slim',
      options: Options(headers: {
        if (token != null) 'Authorization': 'Bearer $token',
        'Accept': manifestAccept,
      }),
    );
    final layers = manifest.data?['layers'] as List? ?? const [];
    final digest =
        layers.isEmpty ? null : (layers.first as Map)['digest'] as String?;
    if (digest == null) throw Exception('manifest 中无层信息');

    await _dio.download('$base/v2/library/debian/blobs/$digest', savePath,
        options: Options(headers: {
          if (token != null) 'Authorization': 'Bearer $token',
        }));
  }

  Future<void> _postConfigure(TerminalDistro d, String rootfs) async {    if (d == TerminalDistro.alpine) {
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
    final proot = await prootPath();
    final tmp = await getTemporaryDirectory();
    final shell = d == TerminalDistro.alpine ? '/bin/sh' : '/bin/bash';
    final binds = <String>[
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
    ];
    try {
      final ws = await workspaceDir();
      if (ws.isNotEmpty) binds.addAll(['-b', '$ws:/workspace']);
    } catch (_) {}
    return Process.start(
      proot,
      [
        '-r', rootfs,
        '-0',
        '-w', '/root',
        '--link2symlink',
        ...binds,
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

/// 自启动任务：App 启动时在终端环境内拉起的常驻命令。
class TerminalTask {
  final String name;
  final String command;
  final bool enabled;
  final TerminalDistro distro;

  const TerminalTask({
    required this.name,
    required this.command,
    this.enabled = true,
    this.distro = TerminalDistro.alpine,
  });

  TerminalTask copyWith({String? name, String? command, bool? enabled, TerminalDistro? distro}) =>
      TerminalTask(
        name: name ?? this.name,
        command: command ?? this.command,
        enabled: enabled ?? this.enabled,
        distro: distro ?? this.distro,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'command': command,
        'enabled': enabled,
        'distro': distro.name,
      };

  factory TerminalTask.fromJson(Map<String, dynamic> j) {
    var d = TerminalDistro.alpine;
    for (final v in TerminalDistro.values) {
      if (v.name == j['distro']) d = v;
    }
    return TerminalTask(
      name: j['name'] as String? ?? '',
      command: j['command'] as String? ?? '',
      enabled: j['enabled'] as bool? ?? true,
      distro: d,
    );
  }

  static String encodeList(List<TerminalTask> tasks) =>
      jsonEncode(tasks.map((t) => t.toJson()).toList());

  static List<TerminalTask> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TerminalTask.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
