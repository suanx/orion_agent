import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

class _ToolCheck {
  final String name;
  final String description;
  final String probe;
  const _ToolCheck(this.name, this.description, this.probe);
}

const _toolChecks = <_ToolCheck>[
  _ToolCheck('nodejs', 'Node.js 运行时', 'node --version'),
  _ToolCheck('npm', 'Node.js 包管理器', 'npm --version'),
  _ToolCheck('git', 'Git 版本控制', 'git --version'),
  _ToolCheck('python', 'Python 解释器', 'python3 --version'),
  _ToolCheck('pip', 'Python 包安装器', 'pip3 --version'),
  _ToolCheck('ssh', 'SSH 客户端', 'ssh -V'),
];

/// 终端环境页：Alpine(rootfs) 安装、开发工具检测与安装、命令控制台。
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  bool _busy = false;
  final _log = StringBuffer();
  final _checks = <String, (bool, String?)>{}; // probeName -> (ready, version)
  bool _checked = false;
  final _cmdCtrl = TextEditingController();

  TerminalService get _terminal => ref.read(terminalServiceProvider);

  void _appendLog(String s) {
    _log.writeln(s);
    if (mounted) setState(() {});
  }

  Future<void> _installEnv() async {
    setState(() => _busy = true);
    try {
      await _terminal.install(onProgress: _appendLog);
    } catch (e) {
      _appendLog('安装失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstallEnv() async {
    await _terminal.uninstall();
    _appendLog('环境已删除');
    if (mounted) setState(() => _checked = false);
  }

  Future<void> _checkTools() async {
    setState(() => _busy = true);
    _appendLog('检测环境组件…');
    for (final t in _toolChecks) {
      try {
        final r = await _terminal.run('${t.probe} 2>&1 | head -1');
        _checks[t.name] = (r.ok && r.output.trim().isNotEmpty, r.versionLine);
      } catch (_) {
        _checks[t.name] = (false, null);
      }
    }
    _checked = true;
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _installMissing() async {
    setState(() => _busy = true);
    _appendLog('apk add --no-cache nodejs npm git python3 py3-pip openssh sshpass');
    try {
      final r = await _terminal.run(
        'apk add --no-cache nodejs npm git python3 py3-pip openssh sshpass 2>&1 | tail -5',
        timeout: const Duration(minutes: 10),
      );
      _appendLog(r.output.trim().isEmpty ? '完成' : r.output.trim());
      _appendLog('安装结束，重新检测…');
      await _checkTools();
    } catch (e) {
      _appendLog('安装失败：$e');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runCommand() async {
    final cmd = _cmdCtrl.text.trim();
    if (cmd.isEmpty || _busy) return;
    setState(() => _busy = true);
    _appendLog('\$ $cmd');
    try {
      final r = await _terminal.run(cmd);
      _appendLog(r.output.trim().isEmpty ? '（无输出）' : r.output.trim());
    } catch (e) {
      _appendLog('执行失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('终端环境')),
      body: FutureBuilder<bool>(
        future: _terminal.isInstalled(),
        builder: (context, snap) {
          final installed = snap.data ?? false;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _sectionTitle('终端系统'),
              _card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Alpine Linux（proot 沙箱，免 root）',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      installed
                          ? '已就绪。环境内可执行 apk/pip/npm 等包管理，已配置国内镜像。'
                          : '未安装。首次使用需下载约 4MB 的基础系统并解压到应用目录。',
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: Colors.black.withOpacity(0.45)),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      children: [
                        if (!installed)
                          FilledButton.icon(
                            onPressed: _busy ? null : _installEnv,
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: const Text('安装环境'),
                          )
                        else ...[
                          FilledButton.icon(
                            onPressed: _busy ? null : _checkTools,
                            icon: const Icon(Icons.checklist_rounded, size: 18),
                            label: const Text('检测组件'),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _uninstallEnv,
                            child: const Text('删除环境',
                                style: TextStyle(color: Color(0xFFD93025))),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (installed) ...[
                _sectionTitle('开发环境'),
                _card(
                  Column(
                    children: [
                      for (final t in _toolChecks)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(t.name,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600)),
                                    Text(t.description,
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.black
                                                .withOpacity(0.4))),
                                  ],
                                ),
                              ),
                              _statusChip(_checks[t.name]),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (_checked)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _installMissing,
                      icon: const Icon(Icons.build_circle_outlined, size: 18),
                      label: const Text('安装全部组件（apk add）'),
                    ),
                  ),
                _sectionTitle('命令控制台'),
                _card(
                  Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _cmdCtrl,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 13),
                              decoration: const InputDecoration(
                                hintText: '如：uname -a',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              onSubmitted: (_) => _runCommand(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            onPressed: _busy ? null : _runCommand,
                            icon: const Icon(Icons.play_arrow_rounded),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              if (_log.isNotEmpty)
                _card(
                  SizedBox(
                    width: double.infinity,
                    child: SelectableText(
                      _log.toString(),
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.4,
                          color: Colors.black.withOpacity(0.65)),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(s,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black.withOpacity(0.4))),
      );

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: child,
      );

  Widget _statusChip((bool, String?)? state) {
    final (ready, version) = state ?? (false, null);
    final checked = _checked;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: !checked
            ? Colors.black.withOpacity(0.05)
            : (ready
                ? const Color(0xFFE6F4EA)
                : const Color(0xFFFCE8E6)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        !checked ? '未检测' : (ready ? 'ready' : 'lost'),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: !checked
              ? Colors.black45
              : (ready ? const Color(0xFF137333) : const Color(0xFFC5221F)),
        ),
      ),
    );
  }
}
