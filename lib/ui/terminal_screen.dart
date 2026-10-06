import 'dart:async';
import 'dart:io';

import '../theme.dart';
import 'ssh_terminal_screen.dart';
import 'glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/terminal_service.dart';

class _ToolCheck {
  final String name;
  final String description;
  final String probe;

  /// 该组件对应的主二进制名。用于区分「没装」与「装了但探测命令失败」。
  final String binary;
  const _ToolCheck(this.name, this.description, this.probe,
      {required this.binary});
}

/// 探测命令一律**不带管道**（`| head`）。
///
/// 之前用 `'<probe> 2>&1 | head -1'`：如果guest 里没有 `head`
/// （Alpine 精简 rootfs 在极端情况下会缺），整条管道直接失败，
/// exitCode != 0 → 所有组件都显示 lost，而实际原因是「探测方式有问题」
/// 而不是「组件没装」。改成不依赖外部工具，再用 `command -v` 二次确认。
const _toolChecks = <_ToolCheck>[
  _ToolCheck('nodejs', 'Node.js 运行时', 'node --version', binary: 'node'),
  _ToolCheck('npm', 'Node.js 包管理器', 'npm --version', binary: 'npm'),
  _ToolCheck('git', 'Git 版本控制', 'git --version', binary: 'git'),
  _ToolCheck('python', 'Python 解释器', 'python3 --version', binary: 'python3'),
  _ToolCheck('uv', 'Python 项目与包工具', 'uv --version', binary: 'uv'),
  _ToolCheck('pip', 'Python 包安装器', 'pip3 --version', binary: 'pip3'),
  // ssh -V 把版本写进 stderr，退出码仍为 0。
  _ToolCheck('ssh', 'SSH 客户端', 'ssh -V', binary: 'ssh'),
  _ToolCheck('sshd', 'OpenSSH 服务器', 'sshd -V', binary: 'sshd'),
];

/// 终端环境页：Alpine/Debian 双发行版，安装、组件检测、命令控制台。
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _installed = false;
  bool _checked = false;

  /// 环境本身无法启动（rootfs 损坏 / proot 起不来）。
  /// 与「环境正常但组件没装」区分开，避免用户白费力气反复安装。
  bool _envBroken = false;
  final _log = StringBuffer();

  /// 与 [_log] 同步的逐行副本（用于按行裁剪；重复行折叠时以本列表为准）
  final List<String> _logLines = <String>[];
  final _checks = <String, (bool, String?)>{}; // name -> (ready, version)
  final _cmdCtrl = TextEditingController();
  /// 命令控制台输入框焦点：「打开终端」按钮用它把键盘直接顶起来
  final _cmdFocus = FocusNode();
  /// 控制台卡片锚点：用于滚动定位（页面是 ListView，控制台在中部）
  final _consoleKey = GlobalKey();
  late TerminalDistro _distro;

  // Workspace 目录 future 只在 initState 建一次（P1-16）：
  // 原来写在 build 里，安装日志每行一次 setState 都会重建 future，
  // 卡片反复闪烁且重复发起平台通道调用（安装可达 20 分钟）。
  Future<String>? _wsDirFuture;

  // 安装日志逐行 setState 会让整页 rebuild；这里合帧批量刷新（P2-5）。
  bool _pendingDirty = false;
  Timer? _logFlushTimer;

  // 自启动任务列表缓存（P2-5）：原来 build 里每次重新 JSON 解析
  // prefs，改为 initState 读取、_saveTasks 时同步更新。
  List<TerminalTask> _tasks = const [];

  TerminalService get _terminal => ref.read(terminalServiceProvider);

  @override
  void initState() {
    super.initState();
    // specs 理论上非空，但 keys.first 在空 map 上会抛 StateError，这里兜底
    final keys = TerminalService.specs.keys;
    _distro = keys.isEmpty ? TerminalDistro.alpine : keys.first;
    _tasks = _loadTasks();
    _wsDirFuture = _terminal.workspaceDir();
    // 每次进入页面自动检测组件：先刷新安装状态，装好就直接跑检测，
    // 用户不必再点「检测组件」（2026-10-06 用户反馈：进页面什么都没发生）。
    _restoreDistroAndRefresh().then((_) {
      if (mounted && _installed) _checkTools();
    });
    WidgetsBinding.instance.addObserver(this);
  }

  /// 每次回到前台自动重新检测组件（2026-10-05 用户要求）。
  ///
  /// HomeShell 用 IndexedStack 保留四个 Tab，终端页 State 只在首次进入时
  /// 创建——initState 里那一次检测之后，用户反复进出页面看到的都是旧结果。
  /// 组件装在 App 存活期内确实会变（在终端里 apk add / apt install），
  /// 所以「每次进入界面自动检测」是必要的，而不是只在安装后跑一次。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_busy || !_installed) return;
    if (_checked) {
      _appendLog('—— 重新进入页面，自动刷新组件检测 ——');
      _checkTools();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _logFlushTimer?.cancel();
    _cmdCtrl.dispose();
    _cmdFocus.dispose();
    super.dispose();
  }

  /// 「打开终端」：进入**交互式 SSH 终端**全屏页。
  ///
  /// 与上方「命令控制台」的区别：控制台是敲一条命令看一次输出，这里是通过
  /// SSH(127.0.0.1:8022) 连到沙箱里的 pty 持续会话——可以 cd、跑 top、
  /// 连续输入，用法和 Termux 里 `ssh localhost` 一致。沙箱没装 sshd 时
  /// 页面会自动装并拉起服务。
  void _openConsole() {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SshTerminalScreen()));
  }

  /// 显式刷新 Workspace 目录（需要时调用并触发重建）。
  void _refreshWorkspace() {
    if (!mounted) return;
    setState(() => _wsDirFuture = _terminal.workspaceDir());
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

  /// 日志行数上限：安装/诊断的输出可能上千行（并发 proot 探测时尤其），
  /// 超出后丢最旧的，避免 Text 越来越长把渲染拖慢。
  static const _maxLogLines = 400;

  /// 上一行写入的内容与重复次数（用于折叠连续重复行）。
  String? _lastLogLine;
  int _lastLogRepeat = 1;

  /// 收尾上一组重复行：连续相同内容只写一行，出现过多次时补一条「×N」。
  void _flushRepeat() {
    if (_lastLogRepeat > 1) {
      final note = '  ↳ 上行重复 $_lastLogRepeat 次';
      _log.writeln(note);
      _logLines.add(note);
    }
    _lastLogRepeat = 1;
  }

  void _appendLog(String s) {
    final line = s.trimRight();
    if (line.isNotEmpty && line == _lastLogLine) {
      // 重复行：先不写，等下一条不同内容到来时收尾成「×N」
      _lastLogRepeat++;
    } else {
      _flushRepeat();
      _lastLogLine = line;
      _lastLogRepeat = 1;
      // 超上限：一次性丢一半（比每行裁剪便宜），保证日志不会无限膨胀
      if (_logLines.length > _maxLogLines) {
        final kept = _logLines.sublist(_logLines.length - _maxLogLines ~/ 2);
        _log
          ..clear()
          ..writeln(kept.join('\n'));
        _logLines
          ..clear()
          ..addAll(kept);
      }
      _log.writeln(s);
      _logLines.add(s);
    }
    if (!mounted) return;
    // 只标脏 + 100ms 合帧（P2-5）：安装输出每行一次 setState，
    // 长输出时整页 rebuild 频率过高，合并到定时器里统一刷。
    _pendingDirty = true;
    _logFlushTimer ??= Timer(const Duration(milliseconds: 100), () {
      _logFlushTimer = null;
      if (!mounted || !_pendingDirty) return;
      _pendingDirty = false;
      setState(() {});
    });
  }

  Future<void> _installEnv() async {
    setState(() => _busy = true);
    try {
      await _terminal.install(_distro, onProgress: _appendLog);
      await _refreshInstalled();
      _refreshWorkspace();
      // 安装完立即自动检测组件（用户要求：装完就能看到 node/git/python
      // 装没装上，不用再手点一次「检测」）
      await _checkTools();
    } catch (e) {
      // 终端依赖 proot 才能跑。proot 起不来时 rootfs 下载完成但环境不可用，
      // 这里把proot 相关的原因单独拎出来，否则用户只会看到
      // 「安装失败」而不知道是运行库的问题。
      _appendLog('安装失败：${_clip(e.toString())}');
      final msg = e.toString();
      if (msg.contains('proot') || msg.contains('运行库')) {
        _appendLog('原因：终端运行库（proot）不可用。');
        _appendLog('当前安装包可能不是 arm64，或构建时未注入 proot。');
      } else if (msg.contains('No such file')) {
        _appendLog('原因：缺少可执行文件，可能是 proot 未正确打包。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstallEnv() async {
    await _terminal.uninstall(_distro);
    _appendLog('${TerminalService.specOf(_distro).displayName} 环境已删除');
    await _refreshInstalled();
  }

  Future<void> _checkTools() async {
    // 安装过程长达20 分钟，用户中途退出页面时这里会崩
    // （setState after dispose）。
    if (!mounted) return;
    setState(() => _busy = true);
    _envBroken = false;
    _checks.clear();
    _appendLog('检测 ${_distro.name} 环境组件…');
    // 外层 finally：任何未预料的异常都必须复位 _busy，
    // 否则界面永久停在「检测中…」转圈，再也点不动。
    try {
      // 自愈：旧版本安装的环境可能残留「绝对路径符号链接」
      // （Alpine tar 里 /bin/sh → /bin/busybox 这类，平铺解压后指向
      // 宿主文件系统，表现为 /bin/sh 等全部 not found）。
      // 修复成本极低（几百次 lstat），检测前统一跑一遍，老环境无需
      // 重新安装即可恢复。
      try {
        final rootfs = await _terminal.rootfsDir(_distro);
        if (Directory(rootfs).existsSync()) {
          final fixed = _terminal.repairAbsoluteSymlinks(rootfs);
          if (fixed > 0) {
            _appendLog('已自动修复 $fixed 个符号链接'
                '（绝对路径 → 相对路径，旧版安装残留）');
          }
        }
      } catch (_) {}

      // 先确认环境本身能跑起来。rootfs 损坏 / proot 起不来时，
      // 逐个探测只会得到一屏 lost，看不出真实原因。
      try {
        final probe = await _terminal
            .runOn(_distro, 'echo __ok__ && uname -m')
            .timeout(const Duration(seconds: 30));
        final out = probe.output.trim();
        if (!out.contains('__ok__')) {
          _envBroken = true;
          _appendLog('环境无法运行：echo 没有返回预期结果。');
          _appendLog('exitCode=${probe.exitCode} 完整输出=${probe.output.trim()}');
          // 文件层面的诊断：四件套是否部署、rootfs 是否完整，
          // 用户截图这段即可定位「是 APK 不完整还是环境损坏」。
          try {
            _appendLog(await _terminal.diagnose(_distro));
          } catch (_) {}
          // 实验矩阵：递增参数跑 7 组 proot 变体，锁定故障环节。
          try {
            _appendLog('—— 实验矩阵 ——');
            for (final line in await _terminal.probeMatrix(_distro)) {
              _appendLog(line);
            }
            _appendLog('—— 实验矩阵结束 ——');
          } catch (_) {}
          _appendLog('请尝试「删除环境」后重新安装；若诊断为缺失，请重新下载安装最新 APK。');
          return;
        }
        _appendLog('环境可用（${out.split('\n').last.trim()}）');
      } catch (e) {
        _envBroken = true;
        _appendLog('环境无法启动：${_clip(e.toString())}');
        _appendLog('请尝试「删除环境」后重新安装。');
        return;
      }

      // 并发探测，且每个组件独立短超时。
      //
      // 为什么并发：proot 每次启动都要做路径重写，耗时 0.3~2 秒。
      // 9 个组件串行最坏要 9 × 2 = 18 秒，用户看着像卡死。
      // 为什么单项短超时（20s 而非默认 120s）：某个组件的探测命令若在
      // guest 里挂住（组件的 --version 可能尝试联网），
      // 串行下会拖住整轮检测。并发 + 短超时把最坏情况压到 20 秒。
      // 分批并发（每批 3 个），而不是 9 个 proot 同时起：
      // proot 启动时会对 /dev、/tmp 做路径重写与修复，多个实例并发操作
      // 同一份 rootfs/临时目录会互相踩（实测刷出成片的
      // "Deletion failed, path = '/data/utmp'" 噪声，甚至互相删对方的
      // 临时文件）。3 个一批既保留并行提速（9×2s → 3×2s），又避免竞争。
      const batchSize = 3;
      final results = <String?>[];
      for (var start = 0; start < _toolChecks.length; start += batchSize) {
        final batch = _toolChecks.skip(start).take(batchSize).toList();
        final part = await Future.wait<String?>([
          for (final t in batch)
            _terminal
                .runOn(
                  _distro,
                  'if command -v ${t.binary} >/dev/null 2>&1; '
                  'then ${t.probe} 2>&1; '
                  'else echo __missing__; fi',
                  timeout: const Duration(seconds: 20),
                )
                .then<String?>((r) => r.output.trim())
                // 单个组件失败不该中断整轮
                .catchError((Object e) {
              _appendLog('${t.name} 探测异常：${_clip(e.toString())}');
              return null;
            }),
        ]);
        results.addAll(part);
        // 每批完成刷一次，用户能看到进度在走
        if (mounted) setState(() {});
      }

      for (var i = 0; i < _toolChecks.length; i++) {
        final t = _toolChecks[i];
        final text = results[i];
        if (text == null || text.isEmpty || text.contains('__missing__')) {
          _checks[t.name] = (false, null);
        } else {
          _checks[t.name] = (true, _firstLine(text));
        }
        // 每项完成就更新一次，UI 上能看到进度在走而不是一直空白
        if (mounted) setState(() {});
      }

      final okCount = _checks.values.where((v) => v.$1).length;
      _appendLog('检测完成：$okCount/${_toolChecks.length} 个组件可用');
    } catch (e) {
      _appendLog('检测异常终止：${_clip(e.toString())}');
    } finally {
      _checked = true;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 取首个非空行并限长，避免整段输出撑爆日志区。
  static String _firstLine(String s) {
    for (final line in s.split('\n')) {
      final l = line.trim();
      if (l.isNotEmpty) return l.length > 60 ? '${l.substring(0, 60)}…' : l;
    }
    return '';
  }

  static String _clip(String s) =>
      s.length > 120 ? '${s.substring(0, 120)}…' : s;

  Future<void> _installMissing() async {
    setState(() => _busy = true);
    final cmd = TerminalService.installScriptFor(_distro);
    _appendLog('执行：$cmd');
    try {
      // 不用 `| tail -8`：guest 里缺 tail 时整条管道失败，
      // 真正的报错（往往是 apk/apt 的错误行）反而被丢掉，
      // 用户只看到一句「安装失败」。这里保留完整输出，UI 侧限长显示。
      final r = await _terminal.runOn(_distro, cmd,
          timeout: const Duration(minutes: 20));
      final out = r.output.trim();
      if (out.isEmpty) {
        _appendLog('没有输出，退出码 ${r.exitCode}');
      } else {
        // 只展示尾部若干行，但取自完整输出，不依赖 guest 的 tail
        final lines = out.split('\n');
        final tail =
            lines.length > 12 ? lines.sublist(lines.length - 12) : lines;
        _appendLog(tail.join('\n'));
      }
      if (r.ok) {
        _appendLog('安装命令执行成功，重新检测…');
      } else {
        _appendLog('安装命令返回退出码 ${r.exitCode}（上方为错误信息）');
        // Alpine/Debian 的包管理器在网络不通时会以非 0 退出，
        // 这里明确提示，避免用户以为是 App 的问题。
        if (out.contains('Temporary failure') ||
            out.contains('Could not resolve') ||
            out.contains('Network is unreachable')) {
          _appendLog('看起来是网络问题：检查设备是否能访问镜像源。');
        }
        if (out.contains('inaccessible or not found')) {
          // 系统 shell 对 proot/初始程序的报错措辞 —— 文件层面有问题，
          // 附上诊断，用户截图即可定位。
          try {
            _appendLog(await _terminal.diagnose(_distro));
          } catch (_) {}
        }
      }
      await _checkTools();
    } catch (e) {
      _appendLog('安装失败：${_clip(e.toString())}');
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
                        label: Text(TerminalService.specOf(d).displayName),
                      ),
                  ],
                  selected: {_distro},
                  onSelectionChanged: (s) {
                    if (s.isEmpty) return;
                    _switchDistro(s.first);
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  _distro == TerminalDistro.alpine
                      ? 'Alpine：约 4MB，轻量。适合快速命令执行。'
                      : 'Debian 12：约 40MB，完整 glibc 环境。兼容性最好，apt 生态齐全。',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: onSurface(context, 0.45)),
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
                                        fontWeight: FontWeight.w500)),
                                Text(t.description,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: onSurface(context, 0.4))),
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
                  label: Text(_distro == TerminalDistro.alpine
                      ? '安装全部组件（apk add）'
                      : '安装全部组件（apt install）'),
                ),
              ),
            _sectionTitle('命令控制台'),
            // KeyedSubtree 承载锚点：_card(Widget) 没有 key 参数，
            // 直接传 key 会编译不过（v0.2.12 analyze 报错）
            KeyedSubtree(
              key: _consoleKey,
              child: _card(
                Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _cmdCtrl,
                      focusNode: _cmdFocus,
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
              ),
            _sectionTitleWithAction(
              '自启动任务',
              // 「打开终端」：跳到上面的命令控制台并直接唤起键盘——
              // 用户的要求是「新增任务旁加打开终端按钮」：自启动任务本质
              // 是启动后要跑的命令，配置时往往要立刻手动跑一遍验证。
              TextButton.icon(
                onPressed: _openConsole,
                icon: const Icon(Icons.terminal_rounded, size: 18),
                label: const Text('打开终端'),
              ),
            ),
            _card(_buildTasksSection()),
            _sectionTitle('Workspace 挂载'),
            _card(
              FutureBuilder<String>(
                future: _wsDirFuture,
                builder: (context, snap) {
                  final ws = snap.data ?? '…';
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('宿主目录：$ws',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: onSurface(context, 0.55))),
                      const SizedBox(height: 4),
                      Text('已挂载到环境内的 /workspace，与命令控制台、'
                          'Agent 的 run_command 看到同一份文件。'
                          '该目录在系统文件管理器中可直接访问。',
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: onSurface(context, 0.45))),
                    ],
                  );
                },
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
                      color: onSurface(context, 0.65)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- 自启动任务 ----------------

  List<TerminalTask> _loadTasks() => TerminalTask.decodeList(
      ref.read(sharedPreferencesProvider).getString(TerminalService.tasksPrefsKey));

  void _saveTasks(List<TerminalTask> tasks) {
    ref
        .read(sharedPreferencesProvider)
        .setString(TerminalService.tasksPrefsKey, TerminalTask.encodeList(tasks));
    _tasks = tasks;
    if (mounted) setState(() {});
  }

  Widget _buildTasksSection() {
    final tasks = _tasks;
    if (tasks.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('暂无任务。可添加如 `python app.py`、`node server.js` 之类的常驻命令，'
              'App 启动时会自动在环境内拉起已启用的任务。',
              style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: onSurface(context, 0.45))),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _editTask(null),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新增任务'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _openConsole,
                icon: const Icon(Icons.terminal_rounded, size: 18),
                label: const Text('打开终端'),
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      children: [
        for (final t in tasks)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              _terminal.isTaskRunning(t.name)
                  ? Icons.circle_rounded
                  : Icons.circle_outlined,
              size: 14,
              color: _terminal.isTaskRunning(t.name)
                  ? const Color(0xFF137333)
                  : onSurface(context, 0.26),
            ),
            title: Text(t.name,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
            subtitle: Text(
                '${t.command}\n${TerminalService.specOf(t.distro).displayName}'
                '${t.enabled ? ' · 开机自启' : ' · 手动'}',
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.3,
                    color: onSurface(context, 0.4))),
            isThreeLine: true,
            onTap: () => _editTask(t),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    _terminal.isTaskRunning(t.name)
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline_rounded,
                    size: 22,
                  ),
                  onPressed: () async {
                    if (_terminal.isTaskRunning(t.name)) {
                      _terminal.stopTask(t.name);
                      _appendLog('任务「${t.name}」已停止');
                    } else {
                      _appendLog('启动任务「${t.name}」：${t.command}');
                      await _terminal.startTask(t);
                    }
                    if (mounted) setState(() {});
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () {
                    _terminal.stopTask(t.name);
                    _saveTasks(
                        tasks.where((x) => x.name != t.name).toList());
                  },
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _editTask(null),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('新增任务'),
        ),
      ],
    );
  }

  Future<void> _editTask(TerminalTask? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final cmdCtrl = TextEditingController(text: existing?.command ?? '');
    var enabled = existing?.enabled ?? true;
    var distro = existing?.distro ?? _distro;

    // 输入值随 pop 一起带出（P2-6）：whenComplete 会先 dispose 控制器，
    // 之后再读 ctrl.text 会抛「used after dispose」。
    final saved = await showGlassDialog<(String, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => glassAlertDialog(
          title: Text(existing == null ? '新增任务' : '编辑任务'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '任务名（如：web 服务）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cmdCtrl,
                decoration: const InputDecoration(
                  labelText: '常驻命令',
                  hintText: '如：python3 /workspace/app.py',
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<TerminalDistro>(
                segments: [
                  for (final d in TerminalDistro.values)
                    ButtonSegment(
                        value: d,
                        label: Text(TerminalService.specOf(d).displayName)),
                ],
                selected: {distro},
                onSelectionChanged: (s) {
                  if (s.isEmpty) return;
                  setDialog(() => distro = s.first);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开机自启', style: TextStyle(fontSize: 14)),
                value: enabled,
                onChanged: (v) => setDialog(() => enabled = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(
                    ctx, (nameCtrl.text.trim(), cmdCtrl.text.trim())),
                child: const Text('保存')),
          ],
        ),
      ),
    ).whenComplete(() {
      nameCtrl.dispose();
      cmdCtrl.dispose();
    });
    if (saved == null) return;
    final name = saved.$1;
    final command = saved.$2;
    if (name.isEmpty || command.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('任务名和命令不能为空')));
      }
      return;
    }
    // 任务名与已有任务重复时拒绝保存（P2-23）。
    final dup = _tasks.any((t) => t.name == name && t.name != existing?.name);
    if (dup) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('任务名「$name」已存在，请换一个名字')));
      }
      return;
    }
    final tasks = _tasks.where((t) => t.name != existing?.name).toList()
      ..add(TerminalTask(
          name: name, command: command, enabled: enabled, distro: distro));
    _saveTasks(tasks);
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(s,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: onSurface(context, 0.4))),
      );

  /// 标题 + 右侧操作按钮（用于「自启动任务 → 打开终端」）。
  Widget _sectionTitleWithAction(String s, Widget action) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(s,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: onSurface(context, 0.4))),
            ),
            action,
          ],
        ),
      );

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: surface(context),
          borderRadius: BorderRadius.circular(20),
        ),
        child: child,
      );

  Widget _statusChip((bool, String?)? state, bool checked) {
    final (ready, _) = state ?? (false, null);
    // 环境本身起不来时，所有组件都会被标成「未安装」，
    // 但真实原因是环境坏了 —— 用 [envBroken] 区分这两种情况，
    // 否则用户会去反复「安装全部组件」而问题始终存在。
    final envBroken = checked && _envBroken;
    final label = !checked
        ? '未检测'
        : ready
            ? '已安装'
            : (envBroken ? '环境异常' : '未安装');
    // 语义色（P2-20）：固定浅色底在深色模式下刺眼且对比不足。
    final scheme = Theme.of(context).colorScheme;
    final bg = !checked
        ? onSurface(context, 0.05)
        : ready
            ? scheme.primaryContainer
            : scheme.errorContainer;
    final fg = !checked
        ? onSurface(context, 0.45)
        : ready
            ? scheme.onPrimaryContainer
            : scheme.onErrorContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }
}
