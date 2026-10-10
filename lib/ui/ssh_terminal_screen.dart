import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/terminal_service.dart';
import '../services/ssh_terminal_service.dart';
import '../theme.dart';

/// 应用内交互式终端（全屏）：通过 SSH 连到沙箱内的 sshd。
///
/// 与终端页那个「命令控制台」的区别：控制台是「敲一条命令看一次输出」，
/// 这里是有 pty 的**持续会话**——可以 cd、跑 top、看交互式输出、连续输入，
/// 行为和在 Termux 里 ssh localhost 一致。
///
/// 渲染说明：不是全屏 ANSI 终端模拟器，而是「等宽日志 + 输入行 + 快捷键」
/// （Ctrl-C / Tab / ↑↓ 历史）。绝大多数运维命令（ls / cat / npm / python /
/// unzip / top 的交互输出）在这个形态下都能正常工作；全屏 curses 程序
/// （vim / htop 的全屏模式）会显示异常，届时建议用「命令控制台」执行。
class SshTerminalScreen extends ConsumerStatefulWidget {
  const SshTerminalScreen({super.key});

  @override
  ConsumerState<SshTerminalScreen> createState() => _SshTerminalScreenState();
}

class _SshTerminalScreenState extends ConsumerState<SshTerminalScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  /// 已连接的会话；null = 未连接/已断开
  SshSession? _session;
  String _status = '未连接';
  bool _busy = false; // 启动 sshd / 安装组件等长耗时动作
  final List<String> _history = [];
  int _historyIdx = -1;

  /// 输出缓冲上限：pty 是持续流，不限量会把内存吃满（长时间挂着不用时）
  final _buffer = StringBuffer();
  int _bufferLen = 0;
  static const _maxBufferChars = 200 * 1024;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  @override
  void dispose() {
    _session?.close();
    _flushTimer?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // 输出合帧（2026-10-11 P1）：cat 大文件 / npm install 时输出块高频
  // 到达，旧实现每个块一次 setState 且 SelectableText 全量重排版
  // （200KB 缓冲 = 最坏每帧排 20 万字符）。改为 100ms 合帧——
  // 抄 terminal_screen.dart 已验证的日志合帧方案。
  Timer? _flushTimer;

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 100), () {
      _flushTimer = null;
      if (!mounted) return;
      setState(() {});
      _scrollToBottom();
    });
  }

  void _log(String s) {
    if (!mounted) return;
    _buffer.write(s.endsWith('\n') ? s : '$s\n');
    _bufferLen += s.length + 1;
    // 超限就从中间截断（保留最近的输出）
    if (_bufferLen > _maxBufferChars) {
      final text = _buffer.toString();
      _buffer
        ..clear()
        ..write(text.substring(text.length - _maxBufferChars ~/ 2));
      _bufferLen = _buffer.length;
    }
    _scheduleFlush();
  }

  void _logRaw(String s) {
    if (!mounted) return;
    _buffer.write(s);
    _bufferLen += s.length;
    _scheduleFlush();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  SshTerminalService get _svc =>
      SshTerminalService(ref.read(terminalServiceProvider));

  /// 完整连接流程：确保 sshd 在跑 → SSH 连接 → 挂输出流。
  Future<void> _connect() async {
    if (_busy || _session != null) return;
    setState(() {
      _busy = true;
      _status = '正在启动沙箱 sshd…';
    });
    try {
      if (!await _svc.isSshdInstalled()) {
        final hint = _terminalDistroHint;
        _log('沙箱内未安装 sshd，正在安装（$hint）…');
        final r = await ref.read(terminalServiceProvider).runOn(
              ref.read(terminalServiceProvider).activeDistro,
              _svc.installCommand,
              timeout: const Duration(minutes: 5),
            );
        if (r.exitCode != 0) {
          throw Exception('安装 openssh 失败：${r.output.trim().split('\n').last}');
        }
        _log('openssh 安装完成');
      }
      await _svc.ensureSshd(onLog: _log);
      setState(() => _status = '正在连接 127.0.0.1:${SshTerminalService.port}…');
      final session = await _svc.connect(onLog: _log);
      if (!mounted) {
        session.close();
        return;
      }
      _session = session;
      // 持续收输出：pty 是双向流，stdout/stderr 都要接（类型是
      // Stream<Uint8List>，按 UTF-8 容错解码后清掉 ANSI 控制序列）
      session.shell.stdout.listen((data) {
        _logRaw(stripAnsi(utf8.decode(data, allowMalformed: true)));
      });
      session.shell.stderr.listen((data) {
        _logRaw(stripAnsi(utf8.decode(data, allowMalformed: true)));
      });
      setState(() => _status = '已连接（root@沙箱）');
      _log('提示：输入命令后回车执行；「/workspace」是宿主映射的工作区；'
          '输入 exit 断开。');
    } catch (e) {
      if (mounted) {
        setState(() => _status = '连接失败');
        _log('连接失败：$e');
        _log('提示：上方若有 sshd: 开头的日志，那是服务端自己给的失败原因；'
            '也可先用终端页的「命令控制台」执行 /usr/sbin/sshd -D -e 手动查看。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _terminalDistroHint =>
      ref.read(terminalServiceProvider).activeDistro == TerminalDistro.alpine
          ? 'apk add openssh'
          : 'apt install openssh-server';

  void _send() {
    final session = _session;
    if (session == null) return;
    final line = _inputCtrl.text;
    _inputCtrl.clear();
    if (line.trim().isEmpty) return;
    _history.add(line);
    _historyIdx = _history.length;
    session.sendLine(line);
  }

  /// 上下键取历史（从输入框读取已按发送的记录）。
  void _recallHistory(int delta) {
    if (_history.isEmpty) return;
    final next = (_historyIdx + delta).clamp(0, _history.length);
    _historyIdx = next;
    _inputCtrl.text = next < _history.length ? _history[next] : '';
    _inputCtrl.selection = TextSelection.collapsed(
        offset: _inputCtrl.text.length);
  }

  void _sendCtrlC() {
    // pty 里 Ctrl-C 是 \x03：前台进程收到 SIGINT，shell 提示符回来
    _session?.write('\x03');
    _log('^C');
  }

  void _sendTab() => _session?.write('\t');

  void _disconnect() {
    _session?.close();
    _session = null;
    setState(() => _status = '已断开');
    _log('已断开连接（sshd 仍在沙箱内运行，重新进入可秒连）');
  }

  @override
  Widget build(BuildContext context) {
    final connected = _session != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('终端'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(_status,
                  style: TextStyle(
                      fontSize: 12,
                      color: connected
                          ? const Color(0xFF1E8E3E)
                          : Theme.of(context).colorScheme.outline)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF0B0F14),
              child: ListView(
                controller: _scrollCtrl,
                padding: const EdgeInsets.all(12),
                children: [
                  SelectableText(
                    _buffer.toString(),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.35,
                      color: Color(0xFFD6E2E8),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 快捷键条：没有物理键盘时，移动端也能发控制字符
          Container(
            color: surface(context),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                _KeyButton(label: '^C', onTap: _sendCtrlC, tip: '中断'),
                _KeyButton(label: 'Tab', onTap: _sendTab, tip: '补全'),
                _KeyButton(
                    label: '↑',
                    onTap: () => _recallHistory(-1),
                    tip: '上一条'),
                _KeyButton(
                    label: '↓', onTap: () => _recallHistory(1), tip: '下一条'),
                const Spacer(),
                if (connected)
                  TextButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('断开'),
                  )
                else
                  TextButton.icon(
                    onPressed: _busy ? null : _connect,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重连'),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      enabled: connected,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(RegExp(r'[\n\r]')),
                      ],
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 13.5),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: connected ? '输入命令…（回车执行）' : '未连接',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.terminal_rounded, size: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: connected ? _send : null,
                    icon: const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.label, required this.onTap, this.tip});

  final String label;
  final VoidCallback onTap;
  final String? tip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 34),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: const TextStyle(
              fontFamily: 'monospace', fontSize: 12),
        ),
        child: Text(label),
      ),
    );
  }
}
