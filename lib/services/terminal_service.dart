import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'workspace_store.dart';

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
  TerminalService({Dio? dio})
      // dio 5.x 移除了 Dio 实例级 connectTimeout/receiveTimeout setter，
      // 超时只能配在 BaseOptions 上（大包下载 30 分钟上限）。
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 30),
            ));

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
  // ignore: unused_field
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

  /// 各发行版 rootfs 的自有 R2 源（Cloudflare R2 公开访问的完整文件 URL）。
  /// 留空 = 不启用（回退镜像源）；部署 R2 后填入即成为下载链第一优先级
  /// （自有 R2 → 镜像源 → 兜底）。R2 上放与下载源相同的产物：
  /// alpine 为 tar.gz、debian 为 tar.xz（压缩格式与 spec.isGzip 一致，
  /// 走 R2 时无需改 isGz 判断）。
  static const alpineR2Url =
      'https://gr.suen.us.ci/alpine-minirootfs-3.22.6-aarch64.tar.gz';
  static const debianR2Url =
      'https://gr.suen.us.ci/debian-bookworm-arm64-rootfs.tar.xz';

  /// 组件全集（打叉的 agent CLI——codex/Claude Code/DeepSeek/Kimi——不装）。
  static const alpinePackages = [
    'nodejs', 'npm', 'git', 'python3', 'py3-pip', 'uv', 'openssh', 'sshpass',
  ];
  static const debianPackages = [
    'nodejs', 'npm', 'git', 'python3', 'python3-pip',
    'openssh-client', 'openssh-server', 'sshpass', 'ca-certificates', 'curl',
  ];

  static const npmMirror = 'https://registry.npmmirror.com';

  /// 一键安装脚本：系统包 + uv(Debian 走 pip)。
  /// npm 仅配置国内镜像（rootfs 内 node 生态自用），不再安装 opencode-ai
  /// （2026-10-05 用户要求移除 OpenCode CLI 组件）。
  static String alpineInstallScript() =>
      'apk add --no-cache ${alpinePackages.join(' ')} && '
      'npm config set -g registry $npmMirror';

  static String debianInstallScript() =>
      'apt-get update -qq && '
      'apt-get install -y --no-install-recommends ${debianPackages.join(' ')} && '
      'pip3 install --break-system-packages uv && '
      'npm config set -g registry $npmMirror';

  static String installScriptFor(TerminalDistro d) =>
      d == TerminalDistro.alpine
          ? alpineInstallScript()
          : debianInstallScript();

  final Dio _dio;
  final _rootfsCache = <TerminalDistro, String>{};

  /// key -> 进程；创建中的任务先以 null 占位，防止并发 startTask 重复拉起。
  final _runningTasks = <String, Process?>{};

  /// 进行中的 install()，用作互斥：非空时拒绝新的安装请求。
  Future<void>? _installLock;

  /// 当前激活的发行版（由终端页设置并持久化，Agent 工具使用它）。
  TerminalDistro activeDistro = TerminalDistro.alpine;

  // ---------------- Workspace 挂载 ----------------

  /// 宿主侧工作区目录：用户可在「存储」设置里选择自定义目录
  /// （见 [WorkspaceStore]），在 guest 内固定挂载为 /workspace。
  ///
  /// ⚠️ 不做内存缓存：设置页随时可能改目录，缓存会让改动
  /// 直到重启才生效。
  Future<String> workspaceDir() => WorkspaceStore.path();

  // ---------------- 自启动任务 ----------------

  /// 启动一个常驻任务（同一名字重复调用会忽略）。
  ///
  /// 先同步往任务 map 占位再异步创建进程：并发调用时第二次会命中
  /// 占位直接返回，避免同一任务被拉起两份；创建失败时移除占位并
  /// 原样抛出。
  Future<void> startTask(TerminalTask task) async {
    if (_runningTasks.containsKey(task.name)) return;
    _runningTasks[task.name] = null;
    try {
      final proc = await startOn(task.distro, '${task.command} 2>&1');
      _runningTasks[task.name] = proc;
      unawaited(proc.exitCode
          .whenComplete(() => _runningTasks.remove(task.name)));
    } on Object {
      _runningTasks.remove(task.name);
      rethrow;
    }
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

  /// proot 可执行文件路径（**双路解析**）。
  ///
  /// ⚠️ 部署方式的演变（四个坑都踩过）：
  ///
  /// 1. **asset 复制到 appSupport 再 chmod** —— 依赖库缺失/改名坑已修，
  ///    但当时从未在用户设备上真正验证过（历次报错截图其实来自
  ///    另一个 App，见 docs §11.16）。
  ///
  /// 2. **直接 exec APK 内的 asset** —— 不可行，asset 只读无执行位。
  ///
  /// 3. **jniLibs → nativeLibraryDir 直跑（V0.1.3/4）** —— 用户实测
  ///    仍失败：矩阵输出 `/system/bin/sh: 1: <nativeLibDir>/libproot.so:
  ///    not found`——shell 对一个**存在且合法**的 ELF 报 not found，
  ///    是内核层拒绝加载的典型表现（提取文件 exec 位/SELinux 上下文
  ///    因 ROM 而异）。
  ///
  /// 4. **当前方案（V0.1.5，双路）**：
  ///    主路 = 把五件套从 nativeLibraryDir **复制到应用数据目录** +
  ///    chmod 755（targetSdk 28 允许 exec 数据目录二进制）；
  ///    后备 = 复制失败时退回 nativeLibraryDir。
  ///    两路都在实验矩阵里自测上报，用户截图即可知道哪路可用。
  ///
  /// 注意 DT_NEEDED 是 `libtalloc.so`（无 .2 后缀）——这是 vendored
  /// proot 的构建特性，库文件名必须与之一致，改名即链接失败。
  static const _prootLibs = [
    'libproot.so',
    'libproot-loader.so',
    'libproot-loader32.so',
    'libtalloc.so',
    'libandroid-shmem.so',
  ];

  static const _systemChannel = MethodChannel('orion_agent/system');

  String? _libDir;
  String? _prootPath;

  /// proot 全套所在的目录（nativeLibraryDir）。
  Future<String> prootLibDir() async {
    if (_libDir != null) return _libDir!;
    String dir;
    try {
      dir = await _systemChannel.invokeMethod<String>('nativeLibDir') ?? '';
    } catch (e) {
      throw Exception('无法获取 nativeLibraryDir（$e）。');
    }
    if (dir.isEmpty) {
      throw Exception('nativeLibraryDir 为空：APK 可能未正确打包 native 库。');
    }
    return _libDir = dir;
  }

  /// proot 可执行文件路径。
  Future<String> prootPath() async {
    if (_prootPath != null) return _prootPath!;
    // ---- 主路：复制到 appSupport/bin + chmod 755 ----
    try {
      final dir = await prootLibDir();
      final support = await getApplicationSupportDirectory();
      final binDir = Directory('${support.path}/bin');
      if (!binDir.existsSync()) binDir.createSync(recursive: true);
      var ok = true;
      for (final name in _prootLibs) {
        final src = File('$dir/$name');
        final dst = File('${binDir.path}/$name');
        try {
          if (!src.existsSync()) {
            ok = false;
            break;
          }
          // 按大小增量复制：升级后字节数变化会自动刷新
          if (!dst.existsSync() ||
              (await dst.stat()).size != (await src.stat()).size) {
            await src.copy(dst.path);
          }
          final chmod =
              await Process.run('/system/bin/chmod', ['755', dst.path]);
          if (chmod.exitCode != 0) ok = false;
        } catch (_) {
          ok = false;
        }
      }
      if (ok) {
        return _prootPath = '${binDir.path}/libproot.so';
      }
    } catch (_) {
      // 复制链路任一环失败 → 走后备
    }
    // ---- 后备：nativeLibraryDir 直跑 ----
    final dir = await prootLibDir();
    final proot = '$dir/libproot.so';
    if (!File(proot).existsSync()) {
      throw Exception(
          '$proot 不存在，且复制部署失败。请重新安装最新版 APK。');
    }
    return _prootPath = proot;
  }

  /// proot 子进程环境变量（对齐 aicode 的验证过的组合）。
  ///
  /// - 必须先合并 [Platform.environment]：Dart 的 Process 与 Java 的
  ///   ProcessBuilder 不同——给了 environment 就**完全替换**父进程环境，
  ///   而 proot（bionic 动态链接程序）需要 ANDROID_ROOT/ANDROID_DATA 等
  ///   系统变量才能正常工作。aicode 注释证实：只喂自定义环境会让 proot
  ///   exec 瞬间失败（终端表现为「会话已结束」且无其他报错）。
  /// - 库/loader/proot 必须同目录（[prootPath] 保证），LD_LIBRARY_PATH
  ///   除该目录外还要带 /system/lib64:/system/lib。
  /// - PROOT_LOADER_32 也要设：32 位客户程序用 loader32，缺了它
  ///   执行 32 位 ELF 时按编译进去的 Termux 路径找必败。
  /// - **刻意不设 PROOT_NO_SECCOMP**：这是 Termux 自己用 proot 的方式；
  ///   aicode 实测强制全量 ptrace 反而在部分设备触发 ptrace(PEEKDATA)
  ///   I/O error。
  Future<Map<String, String>> prootEnv() async {
    final proot = await prootPath();
    final dir = proot.substring(0, proot.lastIndexOf('/'));
    final tmp = await getTemporaryDirectory();
    if (!Directory(tmp.path).existsSync()) {
      Directory(tmp.path).createSync(recursive: true);
    }
    return {
      ...Platform.environment,
      'PROOT_TMP_DIR': tmp.path,
      'PROOT_LOADER': '$dir/libproot-loader.so',
      'PROOT_LOADER_32': '$dir/libproot-loader32.so',
      'LD_LIBRARY_PATH': '$dir:/system/lib64:/system/lib',
      'HOME': '/root',
      'TMPDIR': '/tmp',
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'LANG': 'C.UTF-8',
    };
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
  ///
  /// 安全顺序：先下载到临时压缩包 → 解压到全新 `rootfs.tmp` → 结构验证
  /// → 权限/链接修复 → **全部成功后**才删旧 rootfs 并把 tmp 改名为正式
  /// rootfs。镜像返回 HTML 错误页/截断时旧环境不会被破坏；无论成败，
  /// finally 都会清理临时压缩包与残留的 tmp 目录。
  ///
  /// 互斥：同一时间只允许一个安装流程。
  Future<void> install(
    TerminalDistro d, {
    void Function(String progress)? onProgress,
  }) async {
    if (_installLock != null) {
      throw Exception('正在安装中，请等待当前安装完成后再试');
    }
    final op = _doInstall(d, onProgress: onProgress);
    _installLock = op;
    try {
      await op;
    } finally {
      if (identical(_installLock, op)) _installLock = null;
    }
  }

  Future<void> _doInstall(
    TerminalDistro d, {
    void Function(String progress)? onProgress,
  }) async {
    final spec = specOf(d);
    if (spec.downloadUrl.isEmpty) {
      throw Exception('终端环境未配置下载地址：${d.name}');
    }
    final rootfs = await rootfsDir(d);
    final tmpRootfs = '$rootfs.tmp';
    final tmp = await getTemporaryDirectory();
    final archivePath = '${tmp.path}/${spec.dirName}.tar';

    void report(String msg) => onProgress?.call(msg);

    var isGz = spec.isGzip;
    var renamed = false;
    try {
      // 开场先清历史回收站（上次安装/卸载 _deletePathRobust 兜底改名后
      // 没能删掉的孤儿目录），防止 files/ 下的残留越攒越大。
      // ⚠️ 这一步同时是自愈入口：修复前版本留下的卡死残留
      // debian-rootfs.tmp（上百 MB、每次重试都删失败）在这里被
      // 重试+回收站策略强制清掉。
      await _cleanTrashDirs(rootfs, spec.dirName, report: report);

      report('下载 ${spec.displayName} 基础系统…');
      // 下载链：自有 R2 源（配置了地址时，第一优先）→ 各发行版的镜像/备用源
      var r2Ok = false;
      final r2Url =
          d == TerminalDistro.debian ? debianR2Url : alpineR2Url;
      if (r2Url.isNotEmpty) {
        try {
          report('尝试自有 R2 源…');
          await _dio.download(r2Url, archivePath);
          // R2 上放的是与 spec 下载源相同的产物，压缩格式一致，
          // isGz 维持 spec.isGzip 不变
          r2Ok = true;
        } catch (e) {
          report('R2 源不可用（${e.toString().split('\n').first}），转镜像源…');
        }
      }
      if (!r2Ok && d == TerminalDistro.debian) {
        var mirrorOk = false;
        try {
          await _downloadDebianFromMirror(report, archivePath);
          isGz = true;
          mirrorOk = true;
        } catch (e) {
          report('国内镜像不可用，改用备用源下载…');
        }
        if (!mirrorOk) {
          try {
            await _dio.download(spec.downloadUrl, archivePath);
            isGz = false;
          } catch (e) {
            throw Exception(
                'Debian 基础系统下载失败：自有 R2 源、国内镜像与备用源（GitHub）'
                '均不可用。请检查网络后重试（${e.toString().split('\n').first}）');
          }
        }
      } else if (!r2Ok) {
        await _dio.download(spec.downloadUrl, archivePath);
      }

      report('解压 rootfs…');
      // 解压到全新 tmp 目录：旧 rootfs 在验证全部通过前保持原样。
      // 残留清理走健壮删除：上万个文件的目录树直接 deleteSync(recursive)
      // 在 Android 上会间歇性 ENOTEMPTY（见 _deletePathRobust 注释），
      // 此前正是这里删失败 → 报错顶掉真因 → 残留卡死 → 重装永远失败。
      final tmpHandle = Directory(tmpRootfs);
      if (tmpHandle.existsSync()) {
        report('清理上次安装残留…');
        await deletePathRobust(tmpRootfs, report: report);
      }
      tmpHandle.createSync(recursive: true);

      // 解压在独立 isolate 内进行（大 tar 的解码 + 落盘会阻塞 UI 数十秒）。
      //
      // ⚠️ 不能用 `Isolate.run(() => _extractRootfs(...))` 这类闭包写法：
      // 真机上报「object is unsendable - Class: _Timer」安装失败——
      // 闭包跨 isolate 发送时会整体序列化其捕获链，任何一处带出
      // 不可发送对象（如 UI 进度回调 _appendLog 所在 State 持有的
      // 日志合帧 _logFlushTimer）都会在 send 时炸掉。
      // 改为 Isolate.spawn + 顶层入口函数：跨界只有一条纯数据 record
      // （SendPort/路径/bool），没有任何捕获对象可以外泄。
      // 进度不跨 isolate：isolate 内只做纯 dart:io/archive 操作，
      // 统计结果一次性带回，由主 isolate 统一打日志。
      final stats =
          await extractRootfsInIsolate(archivePath, tmpRootfs, isGz);
      if (stats.skippedUnsafe > 0) {
        debugPrint('TerminalService: 解压时已拒绝并跳过 '
            '${stats.skippedUnsafe} 个不安全/无法解析的 tar 条目');
      }
      report('  已创建 ${stats.createdLinks} 个符号链接'
          '${stats.skippedUnsafe > 0 ? '（跳过 ${stats.skippedUnsafe} 个可疑条目）' : ''}');

      // 结构验证：镜像返回 HTML 错误页/压缩包截断时这里会失败，
      // 抛异常走 catch → finally 清理 tmp 目录，旧 rootfs 安然无恙。
      // 期望结构与下载源对应（见 isInstalled/startOn）：
      // alpine → bin/busybox；debian（usrmerge，/bin → usr/bin）→ bin/bash。
      final marker = d == TerminalDistro.alpine
          ? '$tmpRootfs/bin/busybox'
          : '$tmpRootfs/bin/bash';
      if (!File(marker).existsSync()) {
        throw Exception('rootfs 结构校验失败：缺少 $marker，下载内容可能已损坏');
      }

      report('修正执行权限…');
      // rootfs 内二进制需要 exec 位；dart:io 无 chmod，借用系统 toybox
      await Process.run('/system/bin/chmod', ['-R', '755', tmpRootfs]);

      report('修正符号链接…');
      // Alpine/Debian 的 tar 里大量符号链接是**绝对目标**
      // （如 /bin/sh → /bin/busybox，alpine-minirootfs-3.22 有 306 个）。
      // 平铺解压后它们指向宿主文件系统，宿主没有 /bin/busybox，
      // 于是 File.existsSync 报缺失、proot stat 报 ENOENT——
      // 表现为「环境装好了但所有命令 not found」。
      final fixedLinks = repairAbsoluteSymlinks(tmpRootfs);
      if (fixedLinks > 0) report('  已将 $fixedLinks 个绝对路径链接转为相对');

      // 全部成功：此刻才删旧 rootfs，再把 tmp 改名为正式 rootfs。
      // 删旧 rootfs 同样走健壮删除——它和 tmp 一样是上万文件的目录树，
      // 直删可能 ENOTEMPTY；兜底路径（改名进回收站）能把 rootfs 腾出
      // 位置，保证随后的 rename 不会被残留旧目录卡住。
      final rootfsHandle = Directory(rootfs);
      if (rootfsHandle.existsSync()) {
        await deletePathRobust(rootfs, report: report);
      }
      tmpHandle.renameSync(rootfs);
      renamed = true;

      report('配置 DNS 与镜像…');
      await _postConfigure(d, rootfs);

      report('完成');
    } finally {
      // 失败/成功路径都清理临时压缩包；改名成功后 tmp 已不存在，
      // 失败时把解压残留一并清掉，不留垃圾。
      //
      // ⚠️ 清理必须尽力争先、**绝不向上抛错**：Dart 里 finally 中抛出
      // 的异常会顶掉正在传播的原始异常。此前真机报的
      // 「Deletion failed, path = debian-rootfs.tmp (OS Error: Directory
      // not empty)」正是原始失败被 finally 清理失败掩盖的结果——
      // 真因永远看不见，还留下卡死残留让重装必败。
      await deletePathRobust(archivePath, report: report);
      if (!renamed) {
        await deletePathRobust(tmpRootfs, report: report);
      }
    }
  }

  /// 尽力而为地删除文件/目录树，**绝不抛错**（清理不能比主流程的异常
  /// 更醒目，否则又会出现「真因被 Deletion failed 顶掉」的掩盖事故）。
  ///
  /// 为什么需要它：Android（f2fs/ext4）上对超大目录树（Debian rootfs
  /// 上万文件），dart:io 的 `deleteSync(recursive: true)` 会间歇性
  /// ENOTEMPTY（errno 39）——子项 unlink 完成后父目录短暂仍报非空，
  /// Dart 不做重试，直接抛 Deletion failed。连锁后果：
  /// ① finally 清理失败顶掉真因（见 _doInstall 的 finally 注释）；
  /// ② 残留的 rootfs.tmp（上百 MB）留在 files/ 下；
  /// ③ 下次安装开场删同一残留再次失败 → 安装永久卡死。
  ///
  /// 策略：重试 [attempts] 次（ENOTEMPTY 是瞬态的，间隔后即可删）→
  /// 仍失败则改名为 `.trash-<时间戳>`（rename 是原子操作，对目录
  /// 当前是否「非空」不敏感，几乎不会失败），主流程继续 → 改名后再
  /// 尽力删一次 trash；删不掉就留给下次安装开场 [_cleanTrashDirs] 清。
  ///
  /// [deleteOne] 仅供测试注入，用于强制模拟删除失败走回收站分支。
  static Future<void> deletePathRobust(
    String path, {
    int attempts = 3,
    Duration retryDelay = const Duration(milliseconds: 300),
    void Function(String)? report,
    void Function(String path)? deleteOne,
  }) async {
    void deleteEntity(String p) {
      final type = FileSystemEntity.typeSync(p, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type == FileSystemEntityType.directory) {
        Directory(p).deleteSync(recursive: true);
      } else {
        File(p).deleteSync();
      }
    }

    final impl = deleteOne ?? deleteEntity;
    for (var i = 1; i <= attempts; i++) {
      try {
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          return;
        }
        impl(path);
        return;
      } catch (e) {
        if (i == attempts) {
          report?.call(
              '清理 $path 未成功（${e.toString().split('\n').first}），转入回收站策略');
          break;
        }
        await Future<void>.delayed(retryDelay);
      }
    }
    // 兜底：改名甩开。rename 只动目录项本身，不看目录是否非空，
    // 对 ENOTEMPTY 免疫；主流程立刻解 blocked，垃圾延迟消化。
    try {
      final trash = '$path.trash-${DateTime.now().millisecondsSinceEpoch}';
      // renameSync 是实例方法（FileSystemEntity 无静态 rename），按类型取句柄；
      // 链接按 File 处理——rename 系统调用只动路径本身，不跟随链接
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      final FileSystemEntity entity =
          type == FileSystemEntityType.directory ? Directory(path) : File(path);
      entity.renameSync(trash);
      try {
        impl(trash);
      } catch (_) {
        // 孤儿 trash：不阻塞主流程，下次安装开场统一清理
      }
    } catch (e) {
      // 连 rename 都失败：只能放弃，但不向上抛
      debugPrint('TerminalService: $path 清理彻底失败: $e');
    }
  }

  /// 清理历次安装/卸载遗留的 `.trash-*` 回收站目录（见 [deletePathRobust]）。
  /// 在每次安装开场调用：既是存储兜底，也是修复前版本留下的卡死残留
  /// （如 debian-rootfs.tmp）的自愈入口。
  static Future<void> _cleanTrashDirs(
    String rootfs,
    String dirName, {
    void Function(String)? report,
  }) async {
    final parent = Directory(File(rootfs).parent.path);
    if (!parent.existsSync()) return;
    final List<FileSystemEntity> entries;
    try {
      entries = parent.listSync(followLinks: false);
    } catch (_) {
      return; // 列不出来就跳过，不能让清理阻塞安装
    }
    for (final e in entries) {
      final name = e.uri.pathSegments.isNotEmpty
          ? e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)
          : '';
      if (!name.startsWith('$dirName.tmp.trash-') &&
          !name.startsWith('$dirName.trash-')) {
        continue;
      }
      report?.call('清理历史残留 $name…');
      await deletePathRobust(e.path, report: report);
    }
  }

  /// 解压 rootfs 到 [destDir]：在独立 isolate 内执行（公开给测试回归用）。
  ///
  /// 实现为 `Isolate.spawn` + 顶层入口 [_extractRootfsEntry]：
  /// 跨 isolate 边界的只有一条纯数据 record，不经过任何闭包——
  /// 闭包会把捕获链整体序列化，捕获链上有不可发送对象（Timer / Socket /
  /// StreamController 等）时 send 直接失败（真机 v0.2.8 实测）。
  ///
  /// isolate 内抛出的异常转成字符串传回，在此重新抛出（保留可读原因，
  /// 代价是丢失堆栈——isolate 异常对象本身不可发送）。
  static Future<RootfsExtractStats> extractRootfsInIsolate(
      String archivePath, String destDir, bool isGz) async {
    final port = ReceivePort();
    try {
      await Isolate.spawn(
          _extractRootfsEntry, (port.sendPort, archivePath, destDir, isGz));
      final msg = await port.first;
      if (msg is RootfsExtractStats) return msg;
      throw Exception('解压 rootfs 失败：$msg');
    } finally {
      port.close();
    }
  }

  /// 在独立 isolate 中解压 rootfs 压缩包到 [destDir]。
  ///
  /// 只做纯 dart:io / package:archive 操作（无 Flutter、无回调），
  /// 返回统计（链接数/文件数/被拒绝的条目数）。
  ///
  // 必须迭代 TarFile（而非 ArchiveFile）：符号链接的目标存在 tar
  // 头的 linkname 字段（TarFile.nameOfLinkedFile），条目 content
  // 恒为空——此前误用 content 当目标，300+ 个链接全部被创建成
  // 「空目标」，guest 内一切命令 not found（V0.1.7 根因）。
  // 只有 TarFile 保留 typeFlag 与 nameOfLinkedFile 原始信息。
  static RootfsExtractStats _extractRootfs(
      String archivePath, String destDir, bool isGz) {
    final compressed = File(archivePath).readAsBytesSync();
    final List<int> tarBytes;
    if (isGz) {
      tarBytes = GZipDecoder().decodeBytes(compressed);
    } else {
      tarBytes = XZDecoder().decodeBytes(compressed);
    }
    final decoder = TarDecoder();
    decoder.decodeBytes(tarBytes);
    var createdLinks = 0;
    var createdFiles = 0;
    var skippedUnsafe = 0;
    final hardLinks = <String, String>{}; // 落盘路径 -> rootfs 内目标路径
    for (final tf in decoder.files) {
      // ---- Zip-Slip 校验 ----
      // 拒绝绝对路径条目与含「..」段的条目；其余先按「.」/空段归一化，
      // 拼接后再次确认仍在目标目录内，三重兜底防止逃逸写入。
      final rawName = tf.filename;
      if (rawName.isEmpty || rawName.startsWith('/')) {
        skippedUnsafe++;
        continue;
      }
      final cleanSegs = <String>[];
      var unsafe = false;
      for (final seg in rawName.split('/')) {
        if (seg == '..') {
          unsafe = true;
          break;
        }
        if (seg.isEmpty || seg == '.') continue;
        cleanSegs.add(seg);
      }
      if (unsafe || cleanSegs.isEmpty) {
        skippedUnsafe++;
        continue;
      }
      final path = '$destDir/${cleanSegs.join('/')}';
      if (!path.startsWith('$destDir/')) {
        skippedUnsafe++;
        continue;
      }
      switch (tf.typeFlag) {
        case TarFile.TYPE_SYMBOLIC_LINK:
          final target = tf.nameOfLinkedFile ?? '';
          if (target.isEmpty) continue;
          final link = Link(path);
          // typeSync 不跟随链接：链接已存在（含悬空）则不重复创建，
          // 避免 link.create 撞 EEXIST
          if (FileSystemEntity.typeSync(path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            link.create(target);
            createdLinks++;
          }
          break;
        case TarFile.TYPE_HARD_LINK:
          // 硬链接无独立内容，目标条目在 tar 中先于链接出现；
          // 主循环结束后从已落盘的目标复制内容（alpine 0 个、debian 2 个）
          final target = _safeJoin(destDir, tf.nameOfLinkedFile);
          if (target != null) {
            hardLinks[path] = target;
          }
          break;
        case TarFile.TYPE_DIRECTORY:
          Directory(path).createSync(recursive: true);
          break;
        default:
          // 普通文件（typeFlag '0' / '\0' / '7'）
          final f = File(path);
          f.createSync(recursive: true);
          final bytes = tf.rawContent?.toUint8List();
          if (bytes != null && bytes.isNotEmpty) f.writeAsBytesSync(bytes);
          createdFiles++;
          break;
      }
    }
    // 硬链接落盘：copySync 跟随目标上的符号链接取到真实内容，
    // busybox 类多合一二进制按 argv[0] 分发，副本同样可用
    for (final e in hardLinks.entries) {
      final src = File(e.value);
      if (src.existsSync()) {
        src.copySync(e.key);
      }
    }
    return RootfsExtractStats(
      createdLinks: createdLinks,
      createdFiles: createdFiles,
      skippedUnsafe: skippedUnsafe,
    );
  }

  /// 把 tar 条目内的相对目标路径（硬链接的 linkname）安全拼到
  /// [destDir] 下；绝对路径或含「..」段时返回 null（拒绝）。
  static String? _safeJoin(String destDir, String? rel) {
    if (rel == null || rel.isEmpty || rel.startsWith('/')) return null;
    final segs = <String>[];
    for (final seg in rel.split('/')) {
      if (seg == '..') return null;
      if (seg.isEmpty || seg == '.') continue;
      segs.add(seg);
    }
    if (segs.isEmpty) return null;
    return '$destDir/${segs.join('/')}';
  }

  /// 修复 rootfs 内「绝对路径符号链接」：指向 rootfs 内部的绝对目标
  /// 改写为相对路径（bin/sh → busybox），宿主与 guest 解析都成立。
  ///
  /// 实测 alpine-minirootfs-3.22 的 306 个绝对链接全部指向 rootfs
  /// 内部；指向外部（如 /proc）的链接不在 rootfs 内，检测不到即跳过、
  /// 保留原样。返回修复的链接数（0 = 本来就健康）。
  ///
  /// 同步实现（listSync + lstat 总共几百次，毫秒级）；
  /// 单个链接失败静默跳过，不中断整体修复。
  int repairAbsoluteSymlinks(String rootfs) {
    var repaired = 0;
    final root = Directory(rootfs);
    if (!root.existsSync()) return 0;
    late final List<FileSystemEntity> all;
    try {
      all = root.listSync(recursive: true, followLinks: false);
    } catch (_) {
      return 0;
    }
    for (final e in all) {
      if (e is! Link) continue;
      String target;
      try {
        target = e.targetSync();
      } catch (_) {
        continue;
      }
      if (!target.startsWith('/')) continue;
      // 目标必须存在于 rootfs 内（typeSync 不跟随链接，避免误判
      // 尚未修复的链式链接）
      final innerType =
          FileSystemEntity.typeSync('$rootfs$target', followLinks: false);
      if (innerType == FileSystemEntityType.notFound) continue;
      // 链接在 rootfs 内的目录（parent.path 以 rootfs 为前缀）
      final innerParent = e.parent.path.substring(rootfs.length);
      final rel = _relativePosixPath(innerParent, target);
      if (rel == target) continue; // 已在根目录且无需改写（防御）
      try {
        e.deleteSync();
        Link(e.path).createSync(rel);
        repaired++;
      } catch (_) {
        // 个别链接可能被占用/无权限，跳过即可
      }
    }
    return repaired;
  }

  /// POSIX 相对路径：fromDir（rootfs 内目录，如 '/bin'）到
  /// toAbs（绝对路径，如 '/bin/busybox'）→ 'busybox'。
  static String _relativePosixPath(String fromDir, String toAbs) {
    final from = fromDir.split('/').where((s) => s.isNotEmpty).toList();
    final to = toAbs.split('/').where((s) => s.isNotEmpty).toList();
    var i = 0;
    while (i < from.length && i < to.length && from[i] == to[i]) {
      i++;
    }
    final ups = List<String>.filled(from.length - i, '..');
    return ups.followedBy(to.sublist(i)).join('/');
  }

  // ---------------- 国内镜像拉取（Debian） ----------------

  /// 国内可匿名拉取的 Docker Registry 代理（依次尝试，失败自动换下一个）。
  /// 2026-10-06 按存活探测修剪：dockerproxy.net（bookworm-slim 层 404）、
  /// hub.rat.dev（302 跳转）、docker.chenby.cn / docker.anye.xyz（连不通）
  /// 一律移除，避免「死源刷屏后才轮到可用源」；新增 docker.xuanyuan.me。
  /// 任何一个源失效都不该阻断安装，所以保持可追加。
  static const dockerMirrors = <String>[
    'https://docker.m.daocloud.io',
    'https://docker.1ms.run',
    'https://docker.xuanyuan.me',
    'https://dockerhub.icu',
    'https://docker.awsl9527.cn',
  ];

  Future<void> _downloadDebianFromMirror(
      void Function(String) report, String savePath) async {
    Object? lastError;
    for (final base in dockerMirrors) {
      // 每个源重试一次：首轮失败常是 token 换取/网络抖动，重试能救回
      // 误判的可用源，不必等到列表耗尽。
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          report('尝试镜像 $base …');
          await _pullDockerLayer(base, savePath);
          report('镜像下载完成');
          return;
        } catch (e) {
          lastError = e;
          // DioException 是多行堆栈，直接打出来会把日志刷成一坨看不清，
          // 只保留首行错误摘要。
          final msg = e.toString().split('\n').first;
          report(attempt == 0
              ? '镜像不可用（$msg），重试…'
              : '镜像不可用（$msg），换下一个源…');
        }
      }
    }
    throw Exception(
        '全部国内镜像拉取失败：${lastError.toString().split('\n').first}');
  }

  /// Docker Registry v2 匿名拉取 library/debian:bookworm-slim 的根层。
  ///
  /// ⚠️ 必须同时接受【清单 index】类型：docker library 镜像的 tag 现在指向
  /// 多架构 index（含 provenance/SBOM attestation 子清单），只接受单 manifest
  /// 时部分镜像源会直接返回 index，`layers` 字段不存在 → 全部镜像统一报
  /// 「manifest 中无层信息」，GitHub 备用源在国内又基本连不上，安装必败。
  /// 见 index → 选 linux/arm64 非子清单 → 再取该清单的层。
  Future<void> _pullDockerLayer(String base, String savePath) async {
    const indexAccept = 'application/vnd.docker.distribution.manifest.list.v2+json,'
        'application/vnd.oci.image.index.v1+json';
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

    String? layerDigestOf(Map<String, dynamic> manifest) {
      final layers = manifest['layers'] as List? ?? const [];
      return layers.isEmpty
          ? null
          : (layers.first as Map)['digest'] as String?;
    }

    // manifest（可能直接是单 manifest，也可能是 index）
    final manifest = await _dio.get<Map<String, dynamic>>(
      '$base/v2/library/debian/manifests/bookworm-slim',
      options: Options(headers: {
        if (token != null) 'Authorization': 'Bearer $token',
        'Accept': '$indexAccept,$manifestAccept',
      }),
    );
    final data = manifest.data ?? const <String, dynamic>{};

    if (data['manifests'] is List) {
      // index：选 linux/arm64 的真实镜像清单（跳过 attestation 附属清单）
      final entries = (data['manifests'] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic>? picked;
      for (final e in entries) {
        final platform = (e['platform'] as Map?) ?? const <String, dynamic>{};
        final refType =
            ((e['annotations'] as Map?)?['vnd.docker.reference.type']) as String?;
        if (refType == 'attestation-manifest') continue;
        if (platform['os'] == 'linux' &&
            platform['architecture'] == 'arm64' &&
            platform['variant'] == null) {
          picked = e;
          break;
        }
      }
      if (picked == null) {
        // 严格匹配（无 variant 的 arm64）没命中时放宽到任意 arm64
        for (final e in entries) {
          if (((e['platform'] as Map?)?['architecture']) == 'arm64') {
            picked = e;
            break;
          }
        }
      }
      if (picked == null || picked['digest'] == null) {
        throw Exception('index 中找不到 linux/arm64 镜像清单');
      }
      final sub = await _dio.get<Map<String, dynamic>>(
        '$base/v2/library/debian/manifests/${picked['digest']}',
        options: Options(headers: {
          if (token != null) 'Authorization': 'Bearer $token',
          'Accept': manifestAccept,
        }),
      );
      final digest = layerDigestOf(sub.data ?? const <String, dynamic>{});
      if (digest == null) throw Exception('arm64 清单中无层信息');
      await _dio.download('$base/v2/library/debian/blobs/$digest', savePath,
          options: Options(headers: {
            if (token != null) 'Authorization': 'Bearer $token',
          }));
      return;
    }

    final digest = layerDigestOf(data);
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
    // startOn 也要兜底：它内部要读 asset（proot 几 MB）、准备挂载点，
    // 任何一步卡住（磁盘满、asset 读取异常、proot 权限被系统拒绝）
    // 都会让整个检测无限等待。20s 足够正常启动了。
    final proc = await startOn(d, command).timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw Exception(
          'proot 启动超时（20 秒）。可能缺少执行权限，请重新安装应用。'),
    );
    final buf = StringBuffer();
    final sub1 =
        proc.stdout.cast<List<int>>().transform(utf8.decoder).listen(buf.write);
    final sub2 =
        proc.stderr.cast<List<int>>().transform(utf8.decoder).listen(buf.write);

    int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      proc.kill();
      code = -1;
    }

    await drainProcessStreams(sub1, sub2);
    return TerminalResult(exitCode: code, output: buf.toString());
  }

  /// 启动一个 proot 会话进程（供流式读取）。
  Future<Process> startOn(TerminalDistro d, String command) async {
    final rootfs = await rootfsDir(d);
    final proot = await prootPath();
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
      environment: await prootEnv(),
    );
  }

  /// 环境诊断：终端起不来时输出关键状态，供用户截图反馈。
  ///
  /// 覆盖所有「文件层面」的可能故障点：
  ///   - nativeLibraryDir 里 proot 五件套是否存在、大小是否正常
  ///   - rootfs 是否存在、/bin/sh（symlink）与 busybox 是否就位
  Future<String> diagnose(TerminalDistro d) async {
    final buf = StringBuffer();
    String libDir;
    try {
      libDir = await prootLibDir();
      buf.writeln('[诊断] nativeLibraryDir: $libDir');
    } catch (e) {
      return '[诊断] 获取 nativeLibraryDir 失败：$e';
    }
    for (final name in _prootLibs) {
      final f = File('$libDir/$name');
      if (!f.existsSync()) {
        buf.writeln('[诊断] $name: 缺失');
        continue;
      }
      final size = f.lengthSync();
      // 提取文件的执行位因 ROM 而异：缺执行位 → execve EACCES，
      // 这正是双路部署（复制到数据目录再 chmod）要解决的问题。
      final mode = f.statSync().mode;
      final execBit = (mode & 0x40) != 0;
      buf.writeln('[诊断] $name: $size 字节, 执行位=${execBit ? '有' : '无'}');
    }
    // 运行时实际解析出的位置（filesDir/bin 优先）
    try {
      final p = await prootPath();
      buf.writeln('[诊断] 实际运行位置: $p');
      final pf = File(p);
      if (pf.existsSync()) {
        buf.writeln('[诊断] 运行副本: ${pf.lengthSync()} 字节');
      }
    } catch (e) {
      buf.writeln('[诊断] 运行位置解析失败: $e');
    }
    final rootfs = await rootfsDir(d);
    buf.writeln('[诊断] rootfs: $rootfs '
        '${Directory(rootfs).existsSync() ? '存在' : '缺失'}');
    for (final p in const ['/bin/sh', '/bin/busybox', '/bin/apk', '/root']) {
      final target = '$rootfs$p';
      final isLink = Link(target).existsSync();
      final ok = File(target).existsSync() || Directory(target).existsSync();
      buf.writeln('[诊断] rootfs$p: '
          '${ok ? (isLink ? '存在(链接)' : '存在') : '缺失'}');
    }
    return buf.toString();
  }

  /// 实验矩阵：probe 失败时跑一组「递增参数」的 proot 变体，
  /// 定位故障到底出在哪一环（本体 / rootfs / 初始程序 / 某个参数）。
  ///
  /// 每个变体独立超时并记录退出码与输出，结果拼成多行文本供 UI 展示。
  /// 第 8 组带 PROOT_NO_SECCOMP=1：默认 seccomp 在个别内核会出
  /// EPERM/PEEKDATA 错，这组用于对比定位。
  Future<List<String>> probeMatrix(TerminalDistro d) async {
    final results = <String>[];
    final rootfs = await rootfsDir(d);
    final proot = await prootPath();
    final env = await prootEnv();
    final shell = d == TerminalDistro.alpine ? '/bin/sh' : '/bin/bash';

    Future<void> run(String label, List<String> args,
        {String? exe, Map<String, String>? extraEnv}) async {
      final p = exe ?? proot;
      try {
        final r = await Process.run(p, args,
                environment: {...env, ...?extraEnv})
            .timeout(const Duration(seconds: 15));
        final out =
            '${r.stdout}'.trim().replaceAll('\n', ' ⏎ ');
        final err = '${r.stderr}'.trim().replaceAll('\n', ' ⏎ ');
        String clip(String s) =>
            s.length > 110 ? '${s.substring(0, 110)}…' : s;
        results.add('[$label] exit=${r.exitCode}');
        if (out.isNotEmpty) results.add('   out: ${clip(out)}');
        if (err.isNotEmpty) results.add('   err: ${clip(err)}');
      } on ProcessException catch (e) {
        // errorCode = errno：EACCES(13)=权限拒绝、ENOENT(2)=文件不存在、
        // ENOEXEC(8)=格式不可执行——能直接区分「被拦」还是「文件问题」。
        results.add('[$label] 异常 errno=${e.errorCode}: ${e.message}');
      } catch (e) {
        results.add('[$label] 异常: $e');
      }
    }

    await run('1.proot本体 --version', ['--version']);
    await run('2.仅rootfs+true', ['-r', rootfs, '/bin/true']);
    await run('3.仅rootfs+sh', ['-r', rootfs, shell, '-c', 'echo ok']);
    await run('4.-0(伪装root)', [
      '-r', rootfs, '-0', shell, '-c', 'echo ok',
    ]);
    await run('5.-w /root', [
      '-r', rootfs, '-0', '-w', '/root', shell, '-c', 'echo ok',
    ]);
    await run('6.+link2symlink', [
      '-r', rootfs, '-0', '-w', '/root', '--link2symlink',
      shell, '-c', 'echo ok',
    ]);
    await run('7.+binds(与正式调用一致)', [
      '-r', rootfs, '-0', '-w', '/root', '--link2symlink',
      '-b', '/dev', '-b', '/proc', '-b', '/sys',
      shell, '-c', 'echo ok',
    ]);
    await run('8.同7但PROOT_NO_SECCOMP=1', [
      '-r', rootfs, '-0', '-w', '/root', '--link2symlink',
      '-b', '/dev', '-b', '/proc', '-b', '/sys',
      shell, '-c', 'echo ok',
    ], extraEnv: {'PROOT_NO_SECCOMP': '1'});
    // 对照组：绕过 filesDir 复制，直跑 nativeLibraryDir 里的原件。
    // 若 1-8 全挂而 9 过 → 复制环节有问题；若 9 也挂 → 该 ROM 不允许
    // exec nativeLibraryDir/数据目录其一，双路数据一起看。
    try {
      final native = '${await prootLibDir()}/libproot.so';
      await run('9.对照 nativeLibraryDir 直跑', ['--version'], exe: native);
    } catch (e) {
      results.add('[9.对照 nativeLibraryDir 直跑] 异常: $e');
    }
    return results;
  }

  /// 删除指定发行版的环境。
  ///
  /// 走健壮删除：上万文件的 rootfs 直删在 Android 上可能 ENOTEMPTY，
  /// 失败时改名进回收站，目录项立即让出；残留垃圾由下次安装开场清理。
  Future<void> uninstall(TerminalDistro d) async {
    final rootfs = await rootfsDir(d);
    await deletePathRobust(rootfs);
  }
}

/// 解压统计：由 `TerminalService._extractRootfs` 在 isolate 内完成后
/// 一次性带回主 isolate（简单 int 字段，可安全跨 isolate 传递）。
class RootfsExtractStats {
  final int createdLinks;
  final int createdFiles;
  final int skippedUnsafe;

  const RootfsExtractStats({
    required this.createdLinks,
    required this.createdFiles,
    required this.skippedUnsafe,
  });
}

/// isolate 解压入口：**顶层函数**（非闭包），不携带任何捕获上下文。
///
/// 消息为 (回传端口, 压缩包路径, 目标目录, 是否 gzip) 纯数据 record；
/// 内部异常转成字符串传回（异常对象本身含堆栈引用，不可发送）。
/// 见 `TerminalService.extractRootfsInIsolate` 的注释。
void _extractRootfsEntry((SendPort, String, String, bool) msg) {
  final (port, archivePath, destDir, isGz) = msg;
  try {
    port.send(TerminalService._extractRootfs(archivePath, destDir, isGz));
  } catch (e) {
    port.send(e.toString());
  }
}

/// 等待 stdout/stderr 两个订阅**结束**，带超时兜底。
///
/// ⚠️ 这里**不能**直接 `await sub1.asFuture()` / `await sub2.asFuture()`
/// 且不设超时。那两个 await 等的是「stream 关闭」，不是「进程退出」。
/// proot 会把 stdout/stderr 的文件描述符**继承**给 guest 里的子进程；
/// 只要 guest 内还有任何进程持有这个 fd（后台进程、残留的 apk 进程、
/// 甚至 proot 自身的辅助线程），Dart 侧的 stream 就永远收不到 done
/// 事件—— 于是 `asFuture()` 永不完成。
///
/// 后果：进程早就退出了（`exitCode` 已返回），但调用方一直挂着。
/// 实测症状是终端页「检测 alpine 环境组件…」永久转圈、按钮再点不动
/// （`_busy` 永不复位），而 rootfs 其实早已安装完成。
///
/// 正常情况下 stream 在进程退出时立即 close，这里毫秒级返回；
/// 异常情况最多多等 [grace] 就放行 —— 输出可能不完整，但不会卡死。
///
/// 抽成**顶层函数**（而不是 TerminalService 的方法）是为了能在单元测试里
/// 复现「stream 永不关闭」这个场景（`test/terminal_test.dart`）——
/// runOn 本身依赖真实 Process，无法测试。
///
/// ⚠️ 注意它必须待在 class `TerminalService` **之外**。写在大括号里面、
/// 只是缩进为 0 也不行：Dart 会按成员声明解析成实例方法，
/// 外部 import 就再也找不到它（analyze 报 undefined_function）。
/// 这就是它放在两个 class 之间的原因。
Future<void> drainProcessStreams(
  StreamSubscription<String> sub1,
  StreamSubscription<String> sub2, {
  Duration grace = const Duration(milliseconds: 1500),
}) async {
  try {
    await Future.wait<void>([sub1.asFuture<void>(), sub2.asFuture<void>()])
        .timeout(grace);
  } on TimeoutException {
    // 主动 cancel：否则订阅会泄漏（proot 每次调用泄漏两个）。
    unawaited(sub1.cancel());
    unawaited(sub2.cancel());
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
