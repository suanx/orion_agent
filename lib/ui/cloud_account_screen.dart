import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/cloud_service.dart';

/// 云端服务页：登录/注册、卡密激活、设备管理、服务器地址配置。
///
/// 全部功能可降级：未配置服务器/未登录只是云功能（搜索中继、云端任务、
/// 云端 MCP 工具）不可用，orion 本地功能不受任何影响。
class CloudAccountScreen extends ConsumerStatefulWidget {
  const CloudAccountScreen({super.key});

  @override
  ConsumerState<CloudAccountScreen> createState() => _CloudAccountScreenState();
}

class _CloudAccountScreenState extends ConsumerState<CloudAccountScreen> {
  final _serverCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _isRegister = false;
  bool _showServerEditor = false;
  List<CloudDevice>? _devices;

  @override
  void initState() {
    super.initState();
    _serverCtrl.text = ref.read(cloudServiceProvider).baseUrl ?? '';
    _showServerEditor = !ref.read(cloudServiceProvider).isConfigured;
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _saveServer() async {
    await ref.read(cloudProvider.notifier).setBaseUrl(_serverCtrl.text.trim());
    _toast('服务器地址已保存');
    setState(() {});
  }

  Future<void> _submitAuth() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (email.isEmpty || password.isEmpty) {
      _toast('请填写邮箱和密码');
      return;
    }
    final notifier = ref.read(cloudProvider.notifier);
    final ok = _isRegister
        ? await notifier.register(email, password)
        : await notifier.login(email, password);
    if (!mounted) return;
    _toast(ok ? '登录成功，云端工具已接入 Agent' : '操作失败，请查看错误信息');
  }

  Future<void> _activate() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      _toast('请输入卡密');
      return;
    }
    final ok = await ref.read(cloudProvider.notifier).activate(code);
    if (!mounted) return;
    if (ok) {
      _codeCtrl.clear();
      _toast('激活成功');
    }
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await ref.read(cloudServiceProvider).fetchDevices();
      if (!mounted) return;
      setState(() => _devices = devices);
    } on CloudException catch (e) {
      _toast('设备列表获取失败：${e.message}');
    } catch (_) {
      _toast('设备列表获取失败');
    }
  }

  Future<void> _unbind(CloudDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解绑设备'),
        content: Text('确定解绑「${device.deviceName.isEmpty ? device.deviceId : device.deviceName}」？解绑后该设备需重新登录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('解绑')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(cloudServiceProvider).unbindDevice(device.deviceId);
      await _loadDevices();
    } on CloudException catch (e) {
      _toast('解绑失败：${e.message}');
    } catch (_) {
      _toast('解绑失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cloudProvider);
    final cloud = ref.watch(cloudServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('云端服务')),
      body: state.restoring
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (!cloud.isConfigured) ...[
                  const _Hint(
                    '尚未配置云端服务器。配置并登录后可用：联网搜索/网页抓取中继（国内可达）、'
                    '云端定时任务、云端 MCP 工具。不配置也不影响本地功能。',
                  ),
                  const SizedBox(height: 12),
                ],
                _ServerCard(
                  controller: _serverCtrl,
                  expanded: _showServerEditor || !cloud.isConfigured,
                  onToggle: () => setState(() => _showServerEditor = !_showServerEditor),
                  onSave: _saveServer,
                ),
                const SizedBox(height: 12),
                if (!state.loggedIn) ...[
                  _AuthCard(
                    isRegister: _isRegister,
                    onToggleMode: () => setState(() => _isRegister = !_isRegister),
                    emailCtrl: _emailCtrl,
                    passwordCtrl: _passwordCtrl,
                    busy: state.busy,
                    onSubmit: _submitAuth,
                  ),
                ] else ...[
                  _AccountCard(state: state, onRefresh: () => ref.read(cloudProvider.notifier).refreshStatus()),
                  const SizedBox(height: 12),
                  _ActivateCard(
                    controller: _codeCtrl,
                    busy: state.busy,
                    onActivate: _activate,
                  ),
                  const SizedBox(height: 12),
                  _DevicesCard(
                    devices: _devices,
                    onLoad: _loadDevices,
                    onUnbind: _unbind,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: state.busy
                        ? null
                        : () async {
                            await ref.read(cloudProvider.notifier).logout();
                            if (!mounted) return;
                            setState(() => _devices = null);
                            _toast('已退出登录');
                          },
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('退出登录'),
                  ),
                ],
                if (state.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    state.error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
    );
  }
}

// ---------------- 组件 ----------------

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded,
                size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.controller,
    required this.expanded,
    required this.onToggle,
    required this.onSave,
  });

  final TextEditingController controller;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: onToggle,
              child: Row(
                children: [
                  const Icon(Icons.dns_rounded, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text('服务器地址', style: Theme.of(context).textTheme.titleSmall)),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20),
                ],
              ),
            ),
            if (expanded) ...[
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: '如 orion-cloud.edgeone.app（无需 https:// 前缀）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(onPressed: onSave, child: const Text('保存')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.isRegister,
    required this.onToggleMode,
    required this.emailCtrl,
    required this.passwordCtrl,
    required this.busy,
    required this.onSubmit,
  });

  final bool isRegister;
  final VoidCallback onToggleMode;
  final TextEditingController emailCtrl;
  final TextEditingController passwordCtrl;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('登录')),
                ButtonSegment(value: true, label: Text('注册')),
              ],
              selected: {isRegister},
              onSelectionChanged: (_) => onToggleMode(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailCtrl,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: '邮箱',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: passwordCtrl,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(
                labelText: '密码（至少 8 位，含字母和数字）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : onSubmit,
              child: busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isRegister ? '注册并登录' : '登录'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.state, required this.onRefresh});

  final CloudState state;
  final VoidCallback onRefresh;

  String get _expiry {
    final at = state.planExpiresAt;
    if (at == null) return state.plan == 'free' ? '—' : '永久有效';
    final d = DateTime.fromMillisecondsSinceEpoch(at);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final usage = state.usageToday;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_rounded, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(cloudPlanLabel(state.plan),
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  onPressed: onRefresh,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('有效期至：$_expiry', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text('今日搜索 ${usage['relay_search'] ?? 0} 次',
                    style: Theme.of(context).textTheme.bodySmall),
                Text('今日抓取 ${usage['relay_fetch'] ?? 0} 次',
                    style: Theme.of(context).textTheme.bodySmall),
                Text('今日任务 ${usage['task_run'] ?? 0} 次',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivateCard extends StatelessWidget {
  const _ActivateCard({
    required this.controller,
    required this.busy,
    required this.onActivate,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.key_rounded, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('卡密激活', style: Theme.of(context).textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      hintText: 'ORION-XXXX-XXXX-XXXX-XXXX',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : onActivate,
                  child: const Text('激活'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DevicesCard extends StatelessWidget {
  const _DevicesCard({
    required this.devices,
    required this.onLoad,
    required this.onUnbind,
  });

  final List<CloudDevice>? devices;
  final VoidCallback onLoad;
  final void Function(CloudDevice) onUnbind;

  @override
  Widget build(BuildContext context) {
    final list = devices;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_rounded, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('我的设备', style: Theme.of(context).textTheme.titleSmall),
                ),
                TextButton(onPressed: onLoad, child: const Text('刷新')),
              ],
            ),
            if (list == null)
              Text('点击「刷新」查看已绑定设备', style: Theme.of(context).textTheme.bodySmall)
            else if (list.isEmpty)
              Text('暂无设备', style: Theme.of(context).textTheme.bodySmall)
            else
              ...list.map((d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      d.isCurrent ? Icons.smartphone_rounded : Icons.phone_android_rounded,
                      size: 20,
                    ),
                    title: Text(
                      d.deviceName.isEmpty ? d.deviceId : d.deviceName,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    trailing: d.isCurrent
                        ? const Text('当前设备')
                        : TextButton(
                            onPressed: () => onUnbind(d),
                            child: const Text('解绑'),
                          ),
                  )),
          ],
        ),
      ),
    );
  }
}
