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

  static const _knownHostsMarker = 'orion_agent_managed';

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
    // 1) host key + root 密码 + 配置：一次性做完，失败信息直接抛给页面
    final init = await _terminal.runOn(
      _terminal.activeDistro,
      // shell 片段：ssh-keygen -A 生成 host key；chpasswd 设 root 密码；
      // sshd_config 用 heredoc 落盘（PermitRootLogin yes 必须，
      // 否则密码方式会被拒；ListenAddress 0.0.0.0 让宿主 127.0.0.1 可连）
      'set -e; '
      '[ -f /etc/ssh/sshd_config ] || ssh-keygen -A; '
      'echo "root:$rootPassword" | chpasswd; '
      'printf "%s\\n" "$_knownHostsMarker" > /etc/ssh/orion_agent_sshd; '
      'grep -q $_knownHostsMarker /etc/ssh/sshd_config || '
      'printf "%s\\n" '
      '"Port $port" "ListenAddress 0.0.0.0" "PermitRootLogin yes" '
      '"PasswordAuthentication yes" "KbdInteractiveAuthentication yes" '
      '"UsePAM no" "PermitEmptyPasswords no" '
      '>> /etc/ssh/sshd_config; '
      'echo READY',
      timeout: const Duration(seconds: 60),
    );
    if (init.exitCode != 0 || !init.output.contains('READY')) {
      throw Exception('sshd 初始化失败：${init.output.trim()}');
    }
    onLog?.call('配置就绪，正在启动 sshd…');
    // 2) 后台常驻：startOn 返回的 Process 不等待退出；sshd -D 前台运行
    _sshdProc = await _terminal.startOn(
      _terminal.activeDistro,
      'exec /usr/sbin/sshd -D -e',
    );
    // 3) 等端口就绪（最多 8s）
    for (var i = 0; i < 16; i++) {
      if (await isPortOpen()) {
        onLog?.call('sshd 已就绪（127.0.0.1:$port）');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw Exception('sshd 启动超时（8 秒），可先在下方命令框手动执行 '
        '/usr/sbin/sshd -D -e 查看报错');
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
