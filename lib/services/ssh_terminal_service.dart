import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'terminal_service.dart';

/// 沙箱内 sshd 的生命周期 + SSH 客户端封装（应用内交互式终端的后端）。
///
/// 架构：**App ↔ SSH(127.0.0.1:8022) ↔ proot 内的 OpenSSH 服务器**。
/// proot 不隔离网络（无 `-0` 之外的 netns），guest 里监听的端口宿主可直接
/// 连，因此不需要额外端口转发：
/// 1. [ensureSshd] 探测 8022；没在监听就通过 proot 后台拉起 sshd；
/// 2. [connect] 用 dartssh2 连上，开 pty 拿交互 shell；
/// 3. [SshSession.write] 发输入、[output] 流收输出（页面渲染成日志）。
///
/// 首次拉起前会自动做最小初始化：生成 host key、写一份允许 root 密码登录
/// 的 sshd_config、给 root 设密码（[rootPassword]）——否则 sshd 会因为
/// 没有 host key 直接退出。
class SshTerminalService {
  SshTerminalService(this._terminal);

  final TerminalService _terminal;

  static const port = 8022;
  static const host = '127.0.0.1';

  /// 沙箱 root 密码。首次初始化时通过 `chpasswd` 设定；用户自己用
  /// proot 终端改了密码，这里连不上——属于预期行为（改密码等于主动
  /// 断开 App 的后门）。
  static const rootPassword = 'orion';


  /// 已拉起的 sshd 进程（仅本 App 生命周期内有效，退出页面不杀，
  /// 方便下次进来秒连）。
  Process? _sshdProc;

  bool get isSshdProcessAlive => _sshdProc != null;

  /// 端口是否已被 sshd 监听（可能是 App 拉起的，也可能是用户手动起的）。
  Future<bool> isPortOpen() async {
    try {
      final socket = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 800));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 沙箱里是否装了 sshd（组件检测里的 openssh 包）。
  Future<bool> isSshdInstalled() async {
    try {
      final r = await _terminal.runOn(
        _terminal.activeDistro,
        'command -v sshd || ls /usr/sbin/sshd',
        timeout: const Duration(seconds: 20),
      );
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 组件安装命令（Alpine / Debian 不同）。
  String get installCommand => _terminal.activeDistro == TerminalDistro.alpine
      ? 'apk add --no-cache openssh'
      : 'apt-get update -y && apt-get install -y openssh-server';

  /// 确保 sshd 可用：已监听则直接返回；否则初始化配置并后台拉起。
  ///
  /// [onLog] 用来把后台过程（生成 host key / 报错）回显到终端页，
  /// 否则用户只看到「连接失败」而不知道卡在哪一步。
  Future<void> ensureSshd({void Function(String)? onLog}) async {
    if (await isPortOpen()) {
      onLog?.call('sshd 已在运行（端口 $port）');
      return;
    }
    onLog?.call('正在初始化 sshd…');
    // 1) host key + root 密码 + 运行目录。
    //    ⚠️ 不再往 /etc/ssh/sshd_config 追加指令：sshd_config 里同一关键字
    //    重复出现会直接报 "Bad configuration option" 而拒绝启动（用户/
    //    包管理已经写过 Port/PermitRootLogin 时必踩）。启动参数改用
    //    `sshd -o` 命令行传入——天然幂等，不碰配置文件。
    //    /run/sshd（Debian 的 privilege separation 目录）与 /var/empty
    //    缺失时 sshd 会立刻退出，这是「启动超时」最常见的原因。
    final init = await _terminal.runOn(
      _terminal.activeDistro,
      'set -e; '
      'command -v sshd >/dev/null 2>&1 || test -x /usr/sbin/sshd || '
      '  { echo NO_SSHD; exit 3; }; '
      'ssh-keygen -A >/dev/null 2>&1 || true; '
      'echo "root:$rootPassword" | chpasswd; '
      'mkdir -p /run/sshd /var/empty /etc/ssh /dev/pts; '
      'echo READY',
      timeout: const Duration(seconds: 60),
    );
    if (init.exitCode != 0 || !init.output.contains('READY')) {
      if (init.output.contains('NO_SSHD')) {
        throw Exception('沙箱内没有 sshd，请先安装 openssh 组件');
      }
      throw Exception('sshd 初始化失败：${init.output.trim()}');
    }
    onLog?.call('配置就绪，正在启动 sshd…');
    // 2) 后台常驻：startOn 返回的 Process 不等待退出；sshd -D 前台运行。
    //    端口/允许 root 登录等全部用 -o 传参，幂等且不动配置文件。
    // ⚠️ UsePAM 只有 Debian 系认：Alpine 的 OpenSSH 未编译 PAM 支持，
    // 传 -o UsePAM 会让 sshd 报 "Unsupported option" 并**直接退出**，
    // 表现就是「启动超时」。按发行版拼参数。
    final isAlpine = _terminal.activeDistro == TerminalDistro.alpine;
    final sshdFlags = [
      // 安全（2026-10-11）：必须只听宿主内回环。proot 不隔离网络，
      // 0.0.0.0 会把 sshd 绑到手机所有网卡——同一 Wi-Fi 下任何设备
      // 都能用代码里公开的 root 密码 SSH 进沙箱。宿主内连接 127.0.0.1
      // 本来就是唯一使用方式，无需对外监听。
      '-o ListenAddress=127.0.0.1',
      '-o PermitRootLogin=yes',
      '-o PasswordAuthentication=yes',
      '-o KbdInteractiveAuthentication=yes',
      '-o PermitEmptyPasswords=no',
      if (!isAlpine) '-o UsePAM=no',
    ].join(' ');
    _sshdProc = await _terminal.startOn(
      _terminal.activeDistro,
      'exec /usr/sbin/sshd -D -e -p $port $sshdFlags',
    );
    // 2.1) 把 sshd 自己的 stderr 回显——它是唯一能说清「为什么没起来」
    //     的信息源（缺目录、配置冲突、端口占用、host key 权限…）。
    final diag = StringBuffer();
    void drain(Stream<List<int>> s) {
      s.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final text = line.trim();
        if (text.isEmpty) return;
        diag.writeln(text);
        onLog?.call('sshd: $text');
      });
    }

    try {
      drain(_sshdProc!.stdout);
      drain(_sshdProc!.stderr);
    } catch (_) {}
    var exited = false;
    // catchError 回调必须返回 bool（与 then 链的 Future<bool> 对齐），
    // 否则 analyze 报 body_might_complete_normally_catch_error
    _sshdProc!.exitCode.then((_) => exited = true).catchError((_) => false);

    // 3) 等端口就绪（最多 20s：proot 首次启动要读几 MB 的 proot 二进制
    //    并挂载 /dev /proc /sys，冷启动比后续慢得多）
    for (var i = 0; i < 40; i++) {
      if (await isPortOpen()) {
        onLog?.call('sshd 已就绪（127.0.0.1:$port）');
        return;
      }
      if (exited) {
        throw Exception('sshd 已退出（code=${_sshdProc!.exitCode}）。'
            '上面的 sshd 日志说明了原因。');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw Exception('sshd 启动超时（20 秒）。'
        '${diag.toString().trim().isEmpty ? "没有输出日志" : "见上方 sshd 日志"}');
  }

  /// 连接并开启交互 shell。
  Future<SshSession> connect({void Function(String)? onLog}) async {
    final socket = await SSHSocket.connect(host, port)
        .timeout(const Duration(seconds: 10));
    final client = SSHClient(
      socket,
      username: 'root',
      onPasswordRequest: () => rootPassword,
    );
    onLog?.call('已连接 127.0.0.1:$port，正在申请 pty…');
    final shell = await client.shell().timeout(const Duration(seconds: 10));
    return SshSession._(client: client, shell: shell);
  }
}

/// 一条活着的 SSH 交互会话。
class SshSession {
  SshSession._({required this.client, required this.shell});

  final SSHClient client;

  /// `client.shell()` 的返回类型：带 pty 的会话，stdout/stderr 是
  /// `Stream<Uint8List>`，`write(Uint8List)` 发输入。
  final SSHSession shell;

  /// 关闭连接（页面退出时调用；sshd 进程保持常驻）。
  Future<void> close() async {
    try {
      await client.close();
    } catch (_) {}
  }

  /// 发送一行命令（自动补换行）。
  void sendLine(String line) => write('$line\n');

  /// 发送原始输入（方向键、Ctrl-C 等控制序列走这里）。
  void write(String data) {
    try {
      shell.write(Uint8List.fromList(utf8.encode(data)));
    } catch (_) {}
  }
}

/// ANSI 转义序列清理：sshd 会输出彩色/光标控制码，直接塞进 Text 会显示
/// 成乱码（如 `[32m`）。这里只保留可打印字符 + 常见控制（\r 回车、\n、
/// 制表），其余 ESC 序列整段丢弃。
String stripAnsi(String input) {
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final c = input.codeUnitAt(i);
    if (c == 0x1b) {
      // ESC [ ... 字母（CSI）或 ESC ] ... BEL（OSC）：整段跳过
      if (i + 1 < input.length) {
        final next = input[i + 1];
        if (next == '[') {
          var j = i + 2;
          while (j < input.length && !RegExp(r'[A-Za-z]').hasMatch(input[j])) {
            j++;
          }
          i = j + 1;
          continue;
        }
        if (next == ']') {
          var j = i + 2;
          while (j < input.length && input[j] != '\u0007') {
            j++;
          }
          i = j + 1;
          continue;
        }
      }
      i++;
      continue;
    }
    // \r 归一化：pty 输出里 \r\n 与单独 \r 混用，直接保留会让日志错位
    if (c == 0x0d) {
      i++;
      continue;
    }
    out.writeCharCode(c);
    i++;
  }
  return out.toString();
}
