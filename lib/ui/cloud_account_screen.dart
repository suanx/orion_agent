import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/cloud_service.dart';
import '../theme.dart';
import 'glass.dart';

/// 云端服务页：Hero 风格登录/注册页 + 多功能个人中心。
///
/// 未登录：渐变 Hero（吉祥物 + 功能芯片）+ 服务器配置 + 登录/注册表单。
/// 已登录：账号 Hero（头像/邮箱/套餐/有效期）+ 今日用量 + 卡密激活与
/// 激活记录 + 设备管理 + 服务器地址 + 退出登录。
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
  bool _obscurePassword = true;
  bool _devicesRequested = false;
  bool _devicesLoading = false;
  List<CloudDevice>? _devices;

  @override
  void initState() {
    super.initState();
    _serverCtrl.text = ref.read(cloudServiceProvider).baseUrl ?? '';
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

  // ---------------- 服务器 ----------------

  Future<void> _saveServer() async {
    await ref.read(cloudProvider.notifier).setBaseUrl(_serverCtrl.text.trim());
    if (!mounted) return;
    _toast('服务器地址已保存');
    setState(() {});
  }

  /// 个人中心里通过玻璃对话框修改服务器地址。
  Future<void> _editServerDialog() async {
    final v = await showGlassTextDialog(
      context: context,
      title: '云端服务器',
      labelText: '服务器地址',
      hint: '如 orion-cloud.edgeone.app（无需 https:// 前缀）',
      initialText: _serverCtrl.text,
      confirmLabel: '保存',
    );
    if (v == null) return;
    _serverCtrl.text = v;
    await _saveServer();
  }

  // ---------------- 登录 / 注册 ----------------

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
    if (ok) {
      _devicesRequested = false;
      _toast(_isRegister ? '注册成功，欢迎加入' : '登录成功，云端工具已接入 Agent');
    }
  }

  // ---------------- 卡密 ----------------

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
      _toast('激活成功，套餐已更新');
    }
  }

  // ---------------- 设备 ----------------

  Future<void> _loadDevices({bool silent = false}) async {
    if (!_devicesLoading) {
      setState(() => _devicesLoading = true);
    }
    try {
      final devices = await ref.read(cloudServiceProvider).fetchDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _devicesLoading = false;
      });
    } on CloudException catch (e) {
      if (!mounted) return;
      setState(() => _devicesLoading = false);
      if (!silent) _toast('设备列表获取失败：${e.message}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _devicesLoading = false);
      if (!silent) _toast('设备列表获取失败');
    }
  }

  Future<void> _unbind(CloudDevice device) async {
    final name = device.deviceName.isEmpty ? device.deviceId : device.deviceName;
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: const Text('解绑设备'),
        content: Text('确定解绑「$name」？解绑后该设备需重新登录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('解绑')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(cloudServiceProvider).unbindDevice(device.deviceId);
      await _loadDevices(silent: true);
    } on CloudException catch (e) {
      if (!mounted) return;
      _toast('解绑失败：${e.message}');
    } catch (_) {
      if (!mounted) return;
      _toast('解绑失败');
    }
  }

  // ---------------- 其它 ----------------

  Future<void> _logout() async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后云端搜索中继 / 云端任务 / 云端 MCP 将不可用，本地功能不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD93025),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(cloudProvider.notifier).logout();
    if (!mounted) return;
    setState(() {
      _devices = null;
      _devicesRequested = false;
      _passwordCtrl.clear();
    });
    _toast('已退出登录');
  }

  Future<void> _copyEmail() async {
    final email = ref.read(cloudProvider).email;
    if (email == null || email.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: email));
    _toast('邮箱已复制');
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cloudProvider);
    final cloud = ref.watch(cloudServiceProvider);

    // 登录后自动拉一次设备列表（静默）。
    if (state.loggedIn && !_devicesRequested && !state.restoring) {
      _devicesRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadDevices(silent: true);
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('云端服务')),
      body: state.restoring
          ? const Center(child: CircularProgressIndicator())
          : state.loggedIn
              ? _buildCenter(context, state, cloud)
              : _buildLogin(context, state, cloud),
    );
  }

  // ================= 登录页 =================

  Widget _buildLogin(BuildContext context, CloudState state, CloudService cloud) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ------- Hero -------
        // 液态玻璃卡片（2026-10-06 用户要求：去掉蓝色渐变背景）。
        // 原设计是「主色渐变 + 白字」；换成玻璃后白字在浅色玻璃上不可读，
        // 文字改用 onSurface 体系，胶囊标签用主色淡染。
        SizedBox(
          width: double.infinity,
          child: glassPanel(
            context,
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
              child: Column(
                children: [
                  MascotAvatar(size: 76, image: mascotAsset(context)),
                  const SizedBox(height: 14),
                  Text(
                    'Orion Cloud',
                    style: TextStyle(
                      color: onSurface(context, 0.92),
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '给 Agent 装上云端翅膀\n搜索中继 · 云端任务 · MCP 工具',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: onSurface(context, 0.62),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final label
                          in const ['联网搜索中继', '云端定时任务', '云端 MCP'])
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 11, vertical: 5),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                                color:
                                    scheme.primary.withValues(alpha: 0.22)),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              color: scheme.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),

        // ------- 服务器地址 -------
        if (!cloud.isConfigured) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.dns_outlined,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text('配置云端服务器',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '未配置前云功能不可用',
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.45)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _serverCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: '如 orion-cloud.edgeone.app（无需 https:// 前缀）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _saveServer,
                    child: const Text('保存地址'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ] else ...[
          _CompactRow(
            icon: Icons.dns_outlined,
            label: '服务器',
            value: _hostOf(cloud.baseUrl),
            action: TextButton(
              onPressed: _editServerDialog,
              child: const Text('修改'),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // ------- 登录 / 注册 -------
        Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          decoration: BoxDecoration(
            color: surface(context),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('登录')),
                  ButtonSegment(value: true, label: Text('注册')),
                ],
                selected: {_isRegister},
                onSelectionChanged: (_) =>
                    setState(() => _isRegister = !_isRegister),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: '邮箱',
                  prefixIcon: const Icon(Icons.mail_outline_rounded, size: 20),
                  isDense: true,
                  border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14))),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscurePassword,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitAuth(),
                decoration: InputDecoration(
                  labelText: _isRegister ? '密码（至少 8 位，含字母和数字）' : '密码',
                  prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  isDense: true,
                  border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14))),
                ),
              ),
              if (state.error != null) ...[
                const SizedBox(height: 10),
                Text(
                  state.error!,
                  style: TextStyle(fontSize: 12.5, color: scheme.error),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: state.busy ? null : _submitAuth,
                child: state.busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(_isRegister ? '注册并登录' : '登录'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // ------- 登录后可用 -------
        _Section(
          title: '登录后可用',
          children: [
            _FeatureRow(
              icon: Icons.wifi_tethering_rounded,
              title: '联网搜索 / 网页抓取中继',
              subtitle: '国内直连 DuckDuckGo 不可达，云端代查',
            ),
            _FeatureRow(
              icon: Icons.schedule_rounded,
              title: '云端定时任务',
              subtitle: '任务跑在云端服务器，不占用手机',
            ),
            _FeatureRow(
              icon: Icons.extension_rounded,
              title: '云端 MCP 工具',
              subtitle: '登录自动接入，工具随账号走',
            ),
          ],
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            '登录不影响本地功能 · 令牌经 Keystore 加密存储',
            style: TextStyle(fontSize: 12, color: onSurface(context, 0.4)),
          ),
        ),
      ],
    );
  }

  // ================= 个人中心 =================

  Widget _buildCenter(BuildContext context, CloudState state, CloudService cloud) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ------- 账号 Hero -------
        _AccountHero(
          email: state.email ?? cloud.email ?? '',
          plan: state.plan,
          expiryText: _expiryText(state),
          userId: cloud.userId,
          busy: state.busy,
          onRefresh: () => ref.read(cloudProvider.notifier).refreshStatus(),
          onCopyEmail: _copyEmail,
        ),
        const SizedBox(height: 20),

        // ------- 今日用量 -------
        _Section(
          title: '今日用量',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Row(
                children: [
                  _StatTile(
                    icon: Icons.search_rounded,
                    value: '${state.usageToday['relay_search'] ?? 0}',
                    label: '搜索',
                  ),
                  _StatDivider(),
                  _StatTile(
                    icon: Icons.language_rounded,
                    value: '${state.usageToday['relay_fetch'] ?? 0}',
                    label: '抓取',
                  ),
                  _StatDivider(),
                  _StatTile(
                    icon: Icons.schedule_rounded,
                    value: '${state.usageToday['task_run'] ?? 0}',
                    label: '云端任务',
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ------- 云端授权 -------
        _Section(
          title: '云端授权',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        hintText: 'ORION-XXXX-XXXX-XXXX-XXXX',
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.all(Radius.circular(14))),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: state.busy ? null : _activate,
                    child: const Text('激活'),
                  ),
                ],
              ),
            ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  state.error!,
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text('激活记录',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: onSurface(context, 0.55))),
                  const Spacer(),
                  if (state.licenses.isNotEmpty)
                    Text('${state.licenses.length} 张',
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.4))),
                ],
              ),
            ),
            if (state.licenses.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                child: Text(
                  '暂无激活记录，激活卡密后显示在这里',
                  style: TextStyle(fontSize: 12.5, color: onSurface(context, 0.4)),
                ),
              )
            else
              ...state.licenses.map((lic) => _LicenseRow(license: lic)),
            const SizedBox(height: 8),
          ],
        ),
        const SizedBox(height: 20),

        // ------- 设备管理 -------
        _Section(
          title: '设备管理',
          children: [
            if (_devices == null && !_devicesLoading)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  '登录后自动同步已绑定设备',
                  style: TextStyle(fontSize: 12.5, color: onSurface(context, 0.4)),
                ),
              )
            else if (_devicesLoading && _devices == null)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (_devices!.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text('暂无设备',
                    style: TextStyle(fontSize: 12.5, color: onSurface(context, 0.4))),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 8, 0),
                child: Row(
                  children: [
                    Text('${_devices!.length} 台设备',
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.4))),
                    const Spacer(),
                    IconButton(
                      tooltip: '刷新设备列表',
                      icon: Icon(Icons.refresh_rounded,
                          size: 18, color: onSurface(context, 0.5)),
                      onPressed:
                          _devicesLoading ? null : () => _loadDevices(),
                    ),
                  ],
                ),
              ),
              ..._devices!.map(
                (d) => _DeviceRow(
                  device: d,
                  onUnbind: () => _unbind(d),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),

        // ------- 服务器地址 -------
        _Section(
          title: '设置',
          children: [
            _CompactRow(
              icon: Icons.dns_outlined,
              label: '服务器地址',
              value: _hostOf(cloud.baseUrl),
              action: TextButton(
                onPressed: _editServerDialog,
                child: const Text('修改'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ------- 退出登录 -------
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: state.busy ? null : _logout,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              '退出登录',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFFD93025),
                fontSize: 15.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '退出仅影响云端能力，本地会话与数据不受影响',
            style: TextStyle(fontSize: 12, color: onSurface(context, 0.4)),
          ),
        ),
      ],
    );
  }

  // ---------------- 小工具 ----------------

  String _hostOf(String? base) {
    if (base == null || base.isEmpty) return '未配置';
    return base.replaceFirst(RegExp(r'^https?://'), '');
  }

  String _expiryText(CloudState state) {
    if (state.plan == 'lifetime') return '永久有效';
    final at = state.planExpiresAt;
    if (at == null) return state.plan == 'free' ? '未开通付费套餐' : '有效期 —';
    final d = DateTime.fromMillisecondsSinceEpoch(at);
    final date = '${d.year}-${_two(d.month)}-${_two(d.day)}';
    if (d.isBefore(DateTime.now())) return '已于 $date 过期';
    final left = d.difference(DateTime.now()).inDays + 1;
    return '有效期至 $date · 剩余 $left 天';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

String _fmtDate(int? ms) {
  if (ms == null || ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String _fmtDateTime(int? ms) {
  if (ms == null || ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

// ---------------- 通用组件 ----------------

/// 分组：小标题 + 白色圆角卡片（与「我的」页版式一致）。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: onSurface(context, 0.45),
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: surface(context),
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// 登录页 Hero 下方的一行紧凑信息（服务器地址等）。
class _CompactRow extends StatelessWidget {
  const _CompactRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.action,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 4),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: onSurface(context, 0.65)),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, color: onSurface(context, 0.45)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          action,
        ],
      ),
    );
  }
}

/// 登录页「登录后可用」功能行。
class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 12, color: onSurface(context, 0.45))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 个人中心顶部账号 Hero 卡（渐变）。
class _AccountHero extends StatelessWidget {
  const _AccountHero({
    required this.email,
    required this.plan,
    required this.expiryText,
    required this.userId,
    required this.busy,
    required this.onRefresh,
    required this.onCopyEmail,
  });

  final String email;
  final String plan;
  final String expiryText;
  final String userId;
  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onCopyEmail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = email.isEmpty ? 'O' : email.substring(0, 1).toUpperCase();
    final shortId = userId.isEmpty
        ? '—'
        : (userId.length > 16 ? '${userId.substring(0, 14)}…' : userId);
    // 液态玻璃卡片（2026-10-06 用户要求：去掉蓝色渐变背景）：玻璃自带模糊 +
    // 半透明白底 + 亮边；卡片内文字从白字改为 onSurface 体系才可读。
    return glassPanel(
      context,
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 8, 16),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 头像：邮箱首字母
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: scheme.primary.withValues(alpha: 0.24)),
                ),
                child: Text(
                  initial,
                  style: TextStyle(
                    color: onSurface(context, 0.92),
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            email.isEmpty ? '已登录' : email,
                            style: TextStyle(
                              color: onSurface(context, 0.92),
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            cloudPlanLabel(plan),
                            style: TextStyle(
                              color: onSurface(context, 0.92),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      expiryText,
                      style: TextStyle(
                        color: onSurface(context, 0.62),
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新账号状态',
                icon: busy
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: scheme.primary),
                      )
                    : Icon(Icons.refresh_rounded,
                        color: onSurface(context, 0.92), size: 20),
                onPressed: busy ? null : onRefresh,
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 底部：账号 ID + 长按/点击复制邮箱提示
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onCopyEmail,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.copy_rounded,
                      size: 13, color: onSurface(context, 0.55)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '账号 $shortId · 点按复制邮箱',
                      style: TextStyle(
                        color: onSurface(context, 0.55),
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        ),
        ),
    );
  }
}

/// 今日用量格子。
class _StatTile extends StatelessWidget {
  const _StatTile({required this.icon, required this.value, required this.label});

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: onSurface(context, 0.9),
            ),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(fontSize: 12, color: onSurface(context, 0.45))),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 44,
      color: onSurface(context, 0.07),
    );
  }
}

/// 激活记录一行。
class _LicenseRow extends StatelessWidget {
  const _LicenseRow({required this.license});

  final CloudActivatedLicense license;

  @override
  Widget build(BuildContext context) {
    final duration =
        license.durationDays != null ? ' · ${license.durationDays} 天' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.receipt_long_rounded,
              size: 17, color: onSurface(context, 0.5)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  license.code,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'monospace',
                    color: onSurface(context, 0.85),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${cloudPlanLabel(license.plan)}$duration · ${_fmtDate(license.boundAt)}',
                  style: TextStyle(fontSize: 11.5, color: onSurface(context, 0.42)),
                ),
              ],
            ),
          ),
          Icon(Icons.check_circle_rounded,
              size: 16, color: Theme.of(context).colorScheme.primary),
        ],
      ),
    );
  }
}

/// 设备一行。
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.onUnbind});

  final CloudDevice device;
  final VoidCallback onUnbind;

  @override
  Widget build(BuildContext context) {
    final name =
        device.deviceName.isEmpty ? device.deviceId : device.deviceName;
    final seen = device.lastSeenAt != null
        ? '最近活跃 ${_fmtDateTime(device.lastSeenAt)}'
        : '激活于 ${_fmtDate(device.activatedAt)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
      child: Row(
        children: [
          Icon(
            device.isCurrent
                ? Icons.smartphone_rounded
                : Icons.phone_android_rounded,
            size: 20,
            color: onSurface(context, 0.65),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (device.isCurrent) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '当前设备',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(seen,
                    style: TextStyle(
                        fontSize: 11.5, color: onSurface(context, 0.42))),
              ],
            ),
          ),
          if (!device.isCurrent)
            TextButton(
              onPressed: onUnbind,
              child: const Text('解绑', style: TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
