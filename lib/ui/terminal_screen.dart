import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/providers.dart';
import '../services/terminal_service.dart';

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

const _alpinePackages = ['nodejs', 'npm', 'git', 'python3', 'py3-pip', 'openssh', 'sshpass'];
const _debianPackages = [
  'nodejs', 'npm', 'git', 'python3', 'python3-pip', 'openssh-client', 'sshpass',
];

/// 终端环境页：Alpine/Debian 双发行版，安装、组件检测、命令控制台。
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  bool _busy = false;
  bool _installed = false;
  bool _checked = false;
  final _log = StringBuffer();
  final _checks = <String, (bool, String?)>{}; // name -> (ready, version)
  final _cmdCtrl = TextEditingController();
  late TerminalDistro _distro;

  TerminalService get _terminal => ref.read(terminalServiceProvider);

  @override
  void initState() {
    super.initState();
    _distro = TerminalService.specs.keys.first;
    _restoreDistroAndRefresh();
  }

  Future<void> _restoreDistroAndRefresh() async {
    final saved =
        ref.read(sharedPreferencesProvider).getString('terminal_distro');
    if (saved != null) {
      for (final d in TerminalDistro.values) {
        if (d.name == saved) _distro = d;
      }
    }
    _terminal.activeDistro = _distro;
    await _refreshInstalled();
  }

  Future<void> _refreshInstalled() async {
    final installed = await _terminal.isInstalled(_distro);
    if (mounted) {
      setState(() {
        _installed = installed;
        _checked = false;
      });
    }
  }

  void _switchDistro(TerminalDistro d) {
    if (_busy || d == _distro) return;
    setState(() => _distro = d);
    _terminal.activeDistro = d;
    ref.read(sharedPreferencesProvider).setString('terminal_distro', d.name);
    _refreshInstalled();
  }

  void _appendLog(String s) {
    _log.writeln(s);
    if (mounted) setState(() {});
  }

  Future<void> _installEnv() async {
    setState(() => _busy = true);
    try {
      await _terminal.install(_distro, onProgress: _appendLog);
      await _refreshInstalled();
    } catch (e) {
      _appendLog('安装失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstallEnv() async {
    await _terminal.uninstall(_distro);
    _appendLog('${TerminalService.specs[_distro]!.displayName} 环境已删除');
    await _refreshInstalled();
  }

  Future<void> _checkTools() async {
    setState(() => _busy = true);
    _appendLog('检测 ${_distro.name} 环境组件…');
    for (final t in _toolChecks) {
      try {
        final r = await _terminal.runOn(_distro, '${t.probe} 2>&1 | head -1');
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
    final cmd = _distro == TerminalDistro.alpine
        ? TerminalService.alpineInstallCommand(_alpinePackages)
        : TerminalService.debianInstallCommand(_debianPackages);
    _appendLog(cmd);
    try {
      final r = await _terminal.runOn(_distro, '$cmd 2>&1 | tail -5',
          timeout: const Duration(minutes: 15));
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
      final r = await _terminal.runOn(_distro, cmd);
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _sectionTitle('终端系统'),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<TerminalDistro>(
                  segments: [
                    for (final d in TerminalDistro.values)
                      ButtonSegment(
                        value: d,
                        label: Text(TerminalService.specs[d]!.displayName),
                      ),
                  ],
                  selected: {_distro},
                  onSelectionChanged: (s) => _switchDistro(s.first),
                ),
                const SizedBox(height: 10),
                Text(
                  _distro == TerminalDistro.alpine
                      ? 'Alpine：约 4MB，轻量。适合快速命令执行。'
                      : 'Debian 12：约 40MB，完整 glibc 环境。兼容性最好，apt 生态齐全。',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: Colors.black.withOpacity(0.45)),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  children: [
                    if (!_installed)
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
          if (_installed) ...[
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
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t.name,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600)),
                                Text(t.description,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.black.withOpacity(0.4))),
                              ],
                            ),
                          ),
                          _statusChip(_checks[t.name], _checked),
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
                  label: const Text(
                      _distro == TerminalDistro.alpine
                          ? '安装全部组件（apk add）'
                          : '安装全部组件（apt install）'),
                ),
              ),
            _sectionTitle('命令控制台'),
            _card(
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _cmdCtrl,
                      style:
                          const TextStyle(fontFamily: 'monospace', fontSize: 13),
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

  Widget _statusChip((bool, String?)? state, bool checked) {
    final (ready, _) = state ?? (false, null);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: !checked
            ? Colors.black.withOpacity(0.05)
            : (ready ? const Color(0xFFE6F4EA) : const Color(0xFFFCE8E6)),
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
