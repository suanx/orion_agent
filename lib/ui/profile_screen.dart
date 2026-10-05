import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'glass.dart';
import 'status_bar_area.dart';

import '../providers/providers.dart';
import 'about_screen.dart';
import 'appearance_screen.dart';
import 'cloud_account_screen.dart';
import 'default_models_screen.dart';
import 'font_settings_screen.dart';
import 'knowledge_screen.dart';
import 'mcp_screen.dart';
import 'memory_screen.dart';
import 'notification_settings_screen.dart';
import 'permission_screen.dart';
import 'roles_screen.dart';
import 'settings_screen.dart';
import 'tts_settings_screen.dart';
import 'storage_settings_screen.dart';
import 'terminal_screen.dart';
import 'token_stats_screen.dart';

/// 我的 Tab：分组白卡片列表。
///
/// 版式：每个分组带一行小标题，组内若干行；行内左边图标、中间标题、
/// 右边当前值 + 箭头。
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    final mode = ref.watch(themeModeProvider);
    // 记忆条数走响应式 FutureProvider：懒加载的 MemoryService 直读
    // notes 恒为 0（见 memoryCountProvider 注释）。加载失败显示 '?'，
    // 不阻塞整页渲染。
    final memoryCount = ref.watch(memoryCountProvider);
    final memoryCountLabel = memoryCount.maybeWhen(
      data: (n) => '$n 条',
      orElse: () => '…',
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        // ------- 顶部留白（状态栏）+ 介绍卡 -------
        // StatusBarArea 把状态栏那条区域也涂成页面底色（SafeArea 自身不画背景）
        StatusBarArea(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 20),
              child: _IntroCard(),
            ),
          ),
        ),

        // ------- AI 配置 -------
        _Group(
          title: 'AI 配置',
          children: [
            // 云端服务：登录/注册、卡密激活、设备管理。
            // 未登录只影响云功能（搜索中继/云端任务/云端 MCP），本地功能不受影响。
            _Row(
              icon: Icons.login_rounded,
              label: '云端服务',
              value: ref.watch(cloudProvider).loggedIn
                  ? cloudPlanLabel(ref.watch(cloudProvider).plan)
                  : '未登录',
              onTap: () => _push(context, const CloudAccountScreen()),
            ),
            _Row(
              icon: Icons.cloud_outlined,
              label: 'AI 提供商',
              value: config.configs.isEmpty ? '未配置' : '${config.configs.length} 个',
              onTap: () => _push(context, const SettingsScreen()),
            ),
            _Row(
              icon: Icons.smart_toy_outlined,
              label: '默认模型',
              // 一个提供商下可以有多个模型，所以要把提供商名也显示出来，
              // 否则「gpt-4o-mini」这种名字看不出是哪家配的。
              value: config.activeConfig?.chatModel == null
                  ? '未配置'
                  : (config.configs.length > 1
                      ? '${config.activeConfig!.displayName} · '
                          '${config.activeConfig!.model}'
                      : config.activeConfig!.model),
              onTap: () => _push(context, const DefaultModelsScreen()),
            ),
            _Row(
              icon: Icons.record_voice_over_outlined,
              label: '语音播报',
              value: ref.watch(ttsEnabledProvider) ? '已开启' : '已关闭',
              onTap: () => _push(context, const TtsSettingsScreen()),
            ),
            _Row(
              icon: Icons.dns_outlined,
              label: 'MCP 服务器',
              onTap: () => _push(context, const McpScreen()),
            ),
            _Row(
              icon: Icons.face_retouching_natural_rounded,
              label: 'Agent',
              onTap: () => _push(context, const RolesScreen()),
            ),
          ],
        ),

        // ------- 记忆与知识 -------
        _Group(
          title: '记忆与知识',
          children: [
            _Row(
              // 「记忆」用芯片图标（Material 的 memory），是 AI 记忆功能的
              // 通用视觉符号；原来的灯泡容易和「提示/想法」混淆。
              icon: Icons.memory_outlined,
              label: '长期记忆',
              value: memoryCountLabel,
              onTap: () async {
                await _push(context, const MemoryScreen());
                // 从记忆页返回时可能增删过，刷新计数
                ref.invalidate(memoryCountProvider);
              },
            ),
            _Row(
              // 知识库用图书馆/阅读图标，与「书」相关但和记忆区分开。
              icon: Icons.local_library_outlined,
              label: '知识库',
              onTap: () => _push(context, const KnowledgeScreen()),
            ),
          ],
        ),

        // ------- 运行环境 -------
        _Group(
          title: '运行环境',
          children: [
            _Row(
              icon: Icons.terminal_rounded,
              label: '终端环境',
              onTap: () => _push(context, const TerminalScreen()),
            ),
            _Row(
              icon: Icons.verified_user_outlined,
              label: '应用授权',
              // 不显示动态缺口数：权限在系统设置里改、无回调通知，
              // 静态值不会骗人（动态数会显示过期状态）。
              value: '前往检查',
              onTap: () => _push(context, const PermissionScreen()),
            ),
            _Row(
              icon: Icons.sd_storage_outlined,
              label: '存储',
              onTap: () => _push(context, const StorageSettingsScreen()),
            ),
          ],
        ),

        // ------- 外观与语言 -------
        _Group(
          title: '外观',
          children: [
            _Row(
              icon: Icons.palette_outlined,
              label: '外观主题',
              value: _modeLabel(mode),
              onTap: () => _push(context, const AppearanceScreen()),
            ),
            _Row(
              icon: Icons.format_size_rounded,
              label: '对话字体',
              value: FontSettingsScreen.labelOf(
                  ref.watch(chatFontScaleProvider)),
              onTap: () => _push(context, const FontSettingsScreen()),
            ),
            _Row(
              icon: Icons.notifications_none_rounded,
              label: '通知',
              onTap: () => _push(context, const NotificationSettingsScreen()),
            ),
          ],
        ),

        // ------- 系统 -------
        _Group(
          title: '系统',
          children: [
            _Row(
              icon: Icons.insights_outlined,
              label: 'Token 统计',
              onTap: () => _push(context, const TokenStatsScreen()),
            ),
            _Row(
              icon: Icons.info_outline_rounded,
              label: '关于',
              value: 'V$kAppVersion',
              onTap: () => _push(context, const AboutScreen()),
            ),
          ],
        ),

        const SizedBox(height: 8),
        _DangerButton(
          label: '清空所有会话',
          onTap: () async {
            final ok = await showGlassDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('清空所有会话'),
                content: const Text('将删除本机全部会话记录，不可恢复。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('清空',
                          style: TextStyle(color: Color(0xFFD93025)))),
                ],
              ),
            );
            if (ok == true) {
              await ref.read(chatProvider.notifier).clearAllSessions();
            }
          },
        ),
      ],
    );
  }

  static void _push(BuildContext context, Widget page) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => page));
  }

  static String _modeLabel(ThemeMode m) => switch (m) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
      };
}

/// 顶部介绍卡：吉祥物 + 名称 + 一句话介绍。
class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          MascotAvatar(size: 64, image: mascotAsset(context)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Orion Agent',
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                Text('我 24 小时在线，能搜索、算数、读网页，还有记性。',
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: onSurface(context, 0.55))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个分组：小标题 + 白色圆角卡片。
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
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
            // 必须裁剪：Container 只画背景不裁子节点，
            // 没有它 InkWell 的水波纹会在卡片四角露出直角缺口。
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 52),
                      child: Divider(
                          height: 1, color: onSurface(context, 0.06)),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 组内一行：图标 + 标题 +（右侧值）+ 箭头。
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      // 圆角由外层 _Group 的 Container 提供，这里保持直角，
      // 否则行内的水波纹会在卡片边缘露出直角缺口。
      borderRadius: BorderRadius.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 22, color: onSurface(context, 0.75)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w400),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                // 标题长时不给值无限撑开，留给标题至少 1/3 宽度
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  value!,
                  style: TextStyle(
                      fontSize: 13.5, color: onSurface(context, 0.42)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
            const SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded,
                size: 22, color: onSurface(context, 0.26)),
          ],
        ),
      ),
    );
  }
}

/// 危险操作按钮（清空数据）。
class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: surface(context),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Color(0xFFD93025),
              fontSize: 15.5,
              fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
