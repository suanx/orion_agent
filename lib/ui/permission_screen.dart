import '../theme.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/permission_service.dart';

/// 应用权限授权页。
///
/// 结构对照参考稿（3/4 核心授权样式）：
/// - 顶部：核心授权就绪进度（N / 4 + 进度条 + 提示文案）
/// - 通知与提醒：接收消息通知（开关，Android 13+ 运行时权限）
/// - 核心权限：无障碍 / 后台运行 / 悬浮窗 / 应用列表读取
/// - 扩展能力：所有文件访问权限；Shizuku 暂未支持（不做假开关）
///
/// 全部状态实时查询原生侧（MainActivity permissionStatus），
/// 从系统设置页返回（AppLifecycleState.resumed）后自动刷新。
class PermissionScreen extends ConsumerStatefulWidget {
  const PermissionScreen({super.key});

  @override
  ConsumerState<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends ConsumerState<PermissionScreen>
    with WidgetsBindingObserver {
  PermissionStatus? _status;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页返回时自动刷新（用户在外面改了权限，回来就能看到）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    final s = await ref.read(permissionServiceProvider).status();
    if (mounted) setState(() => _status = s);
  }

  /// 通知开关：开 = 走运行时权限请求；关 = 只能去系统设置关闭
  /// （Android 不允许应用撤销自己的通知权限）。
  Future<void> _toggleNotification(bool on) async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      final svc = ref.read(notificationServiceProvider);
      if (on) {
        await svc.requestPermission();
      } else {
        await ref.read(permissionServiceProvider).open('notification');
      }
      await _reload();
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  /// 跳转系统设置并等待返回刷新。
  Future<void> _open(String kind) async {
    await ref.read(permissionServiceProvider).open(kind);
    // openPermission 的 startActivity 是 fire-and-forget，无法等返回；
    // 这里靠 didChangeAppLifecycleState 的 resumed 刷新，补一次兜底。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;

    return Scaffold(
      backgroundColor: scaffoldBg(context),
      appBar: AppBar(title: const Text('应用权限授权')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                // ---------------- 核心授权进度 ----------------
                Text('${s.coreReady} / 4 项核心授权已就绪',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: s.coreReady / 4,
                    minHeight: 5,
                    backgroundColor: onSurface(context, 0.08),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  s.coreReady == 4
                      ? '全部核心授权已就绪，悬浮交互与后台任务可稳定运行。'
                      : '建议优先补齐核心权限，再执行需要悬浮交互或后台运行的任务。',
                  style: TextStyle(
                      fontSize: 13, height: 1.5, color: onSurface(context, 0.45)),
                ),
                const SizedBox(height: 20),

                // ---------------- 通知与提醒 ----------------
                _sectionLabel(context, '通知与提醒'),
                _card(
                  context,
                  child: SwitchListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    title: const Text('接收消息通知',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    subtitle: Text('打开后可以及时了解任务进度',
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.45))),
                    value: s.notification,
                    onChanged: _requesting ? null : _toggleNotification,
                  ),
                ),
                const SizedBox(height: 20),

                // ---------------- 核心权限 ----------------
                _sectionLabel(context, '核心权限'),
                Text('这些授权用于操作界面、悬浮显示、后台运行和识别已安装应用。',
                    style: TextStyle(
                        fontSize: 12, height: 1.5, color: onSurface(context, 0.45))),
                const SizedBox(height: 8),
                _card(
                  context,
                  child: Column(
                    children: [
                      _PermissionRow(
                        icon: Icons.accessibility_new_rounded,
                        title: '无障碍权限',
                        subtitle: '用于读取页面并执行点击、滑动和输入；'
                            '在系统设置的「无障碍」中开启本应用的服务。',
                        granted: s.accessibility,
                        actionLabel: s.accessibility ? null : '去开启',
                        onOpen: () => _open('accessibility'),
                      ),
                      Divider(height: 1, color: onSurface(context, 0.06)),
                      _PermissionRow(
                        icon: Icons.sync_rounded,
                        title: '后台运行权限',
                        subtitle: '减少系统回收，让消息、定时任务和本机服务'
                            '在后台稳定继续（忽略电池优化）。',
                        granted: s.battery,
                        actionLabel: s.battery ? null : '去开启',
                        onOpen: () => _open('battery'),
                      ),
                      Divider(height: 1, color: onSurface(context, 0.06)),
                      _PermissionRow(
                        icon: Icons.picture_in_picture_alt_rounded,
                        title: '悬浮窗权限',
                        subtitle: '允许应用在其他应用上方显示悬浮内容与任务提醒。',
                        granted: s.overlay,
                        actionLabel: s.overlay ? null : '去开启',
                        onOpen: () => _open('overlay'),
                      ),
                      Divider(height: 1, color: onSurface(context, 0.06)),
                      _PermissionRow(
                        icon: Icons.apps_rounded,
                        title: '应用列表读取',
                        subtitle: '用于识别设备已安装应用，并提供应用上下文。',
                        granted: s.appsList,
                        actionLabel: s.appsList ? null : '去开启',
                        onOpen: () => _open('appsList'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // ---------------- 扩展能力 ----------------
                _sectionLabel(context, '扩展能力'),
                Text('按需开启，可获得更完整的系统级能力与兼容性支持。',
                    style: TextStyle(
                        fontSize: 12, height: 1.5, color: onSurface(context, 0.45))),
                const SizedBox(height: 8),
                _card(
                  context,
                  child: Column(
                    children: [
                      _PermissionRow(
                        icon: Icons.folder_copy_outlined,
                        title: '所有文件访问权限',
                        subtitle: '允许访问设备公共存储中的文件与文件夹，'
                            '用于文件读取、整理和下载等操作。',
                        granted: s.allFiles,
                        actionLabel: s.allFiles ? null : '去开启',
                        onOpen: () => _open('allFiles'),
                      ),
                      Divider(height: 1, color: onSurface(context, 0.06)),
                      _PermissionRow(
                        icon: Icons.terminal_rounded,
                        title: 'Shizuku 权限',
                        subtitle: '暂未支持：需要独立的 Shizuku 服务集成，'
                            '当前应用不依赖它即可完成全部功能。',
                        granted: false,
                        enabled: false,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text('状态由系统实时检测，修改后返回本页自动刷新',
                      style: TextStyle(
                          fontSize: 12, color: onSurface(context, 0.3))),
                ),
              ],
            ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: onSurface(context, 0.45))),
      );

  Widget _card(BuildContext context, {required Widget child}) => Container(
        decoration: BoxDecoration(
          color: surface(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      );
}

/// 单条权限行：图标 + 标题/说明 + 状态（已开启 / 去开启 / 未开启）。
class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.granted,
    this.actionLabel,
    this.onOpen,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool granted;

  /// 尾部动作文案；null 时显示「已开启」。
  final String? actionLabel;

  /// 跳转回调；null 时整行不可点（如暂未支持的项）。
  final VoidCallback? onOpen;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final dim = enabled ? 1.0 : 0.45;

    return ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      onTap: enabled ? onOpen : null,
      leading: Icon(icon, size: 24, color: onSurface(context, 0.6 * dim)),
      title: Text(title,
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: onSurface(context, 0.9 * dim))),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(subtitle,
            style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: onSurface(context, 0.45 * dim))),
      ),
      // isThreeLine 控制两行说明的布局高度
      isThreeLine: subtitle.length > 30,
      trailing: !enabled
          ? Text('暂未支持',
              style: TextStyle(fontSize: 13, color: onSurface(context, 0.35)))
          : granted
              ? Text('已开启',
                  style: TextStyle(fontSize: 13, color: onSurface(context, 0.4)))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(actionLabel ?? '去开启',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: primary)),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: primary),
                  ],
                ),
    );
  }
}
