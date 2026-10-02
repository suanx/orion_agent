import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/terminal_service.dart';

/// 首次运行的环境下载向导：检测到两个终端环境都未安装时展示。
/// 下载全部走国内镜像（Alpine：清华镜像；Debian：国内 Docker 代理）。
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _installed = <TerminalDistro, bool>{};
  final _log = StringBuffer();
  bool _busy = false;

  TerminalService get _terminal => ref.read(terminalServiceProvider);

  @override
  void initState() {
    super.initState();
    _detect();
  }

  Future<void> _detect() async {
    for (final d in TerminalDistro.values) {
      _installed[d] = await _terminal.isInstalled(d);
    }
    if (mounted) setState(() {});
  }

  void _appendLog(String s) {
    _log.writeln(s);
    if (mounted) setState(() {});
  }

  Future<void> _install(TerminalDistro d) async {
    setState(() => _busy = true);
    try {
      await _terminal.install(d, onProgress: _appendLog);
      _installed[d] = await _terminal.isInstalled(d);
      _appendLog('「${TerminalService.specs[d]!.displayName}」环境就绪 ✓');
    } catch (e) {
      _appendLog('安装失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _skip() {
    ref.read(sharedPreferencesProvider).setBool('terminal_setup_done', true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // 只能通过「进入应用」离开，保证用户看到选择
      child: Scaffold(
        appBar: AppBar(title: const Text('欢迎使用 Pocket Agent')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: surface(context),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ClipOval(
                        child: Image.asset('assets/images/mascot.webp',
                            width: 56, height: 56, fit: BoxFit.cover),
                      ),
                      const SizedBox(width: 12),
                      Text('欢迎使用 Pocket Agent',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '检测到本机还没有 Linux 终端环境。'
                    '安装后 Agent 可以执行命令、运行脚本，你也可以使用完整 Linux 工具链。\n\n'
                    '下载全部使用国内镜像，不需要科学上网。'
                    '也可以先跳过，之后在「我的 → 终端环境」中随时安装。',
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: onSurface(context, 0.55)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final d in TerminalDistro.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _distroCard(d),
              ),
            if (_log.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: surface(context),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: SelectableText(
                  _log.toString(),
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.4,
                      color: onSurface(context, 0.65)),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _skip,
              child: Text(
                _installed.values.any((v) => v) ? '完成，进入应用' : '暂不安装，进入应用',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _distroCard(TerminalDistro d) {
    final spec = TerminalService.specs[d]!;
    final installed = _installed[d] ?? false;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(spec.displayName,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: installed
                            ? const Color(0xFFE6F4EA)
                            : onSurface(context, 0.05),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(installed ? '已就绪' : '未安装',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: installed
                                  ? const Color(0xFF137333)
                                  : onSurface(context, 0.45)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  d == TerminalDistro.alpine
                      ? '约 4MB · 轻量快速，清华镜像下载'
                      : '约 20MB · 完整 Debian，国内镜像下载',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: onSurface(context, 0.45)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          installed
              ? const Icon(Icons.check_circle_rounded,
                  color: Color(0xFF137333), size: 28)
              : FilledButton(
                  onPressed: _busy ? null : () => _install(d),
                  child: const Text('安装'),
                ),
        ],
      ),
    );
  }
}
