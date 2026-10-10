import 'dart:async';

import '../theme.dart';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/announcement_service.dart';
import '../services/app_log.dart';
import '../services/navigation_service.dart';
import '../services/terminal_service.dart';
import 'about_screen.dart';
import 'announcement_dialog.dart';
import 'chat_screen.dart';
import 'sessions_drawer.dart';
import 'setup_screen.dart';
import 'skills_screen.dart';
import 'profile_screen.dart';
import 'tasks_screen.dart';
import 'update_dialog.dart';

/// 应用外壳：4 个 Tab + 悬浮液态玻璃底部导航。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _tab = 0;

  static const _navHeight = 64.0;

  void _goChat() => setState(() => _tab = 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowSetup();
      // 冷启动场景：通知回调可能在 runApp 之前就写入了意图，
      // 首帧之后补执行一次（否则会停在默认 Tab）。
      _consumeIntent();
    });
    // 运行中点击通知：切 Tab + 可选预填输入框。
    // 放在 initState 而非 build：build 里注册监听会每次重建都新增一个，
    // 且回调里改 provider 状态会触发「build 期间不可修改 provider」断言。
    ref.listen<NavIntent?>(navIntentProvider, (_, intent) {
      if (intent == null) return;
      // 先清空（见 _consumeIntent 注释），再执行跳转
      ref.read(navIntentProvider.notifier).state = null;
      _applyIntent(intent);
    });
    // 启动自动检查更新：延迟几秒避开启动高峰；
    // 发现新版本弹窗展示（用户要求：每次进入软件都自动检查）。
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoCheckUpdate();
      // 启动后拉一次云端公告。后台新建的公告要在下次打开 App 时弹出来，
      // 延迟 1.2 秒避开启动高峰，也避免与首屏的引导弹窗抢同一时刻。
      Future.delayed(const Duration(milliseconds: 1200), _checkAnnouncement);
    });
  }

  /// 拉取并展示云端公告。
  ///
  /// best-effort：网络不通、后端没配公告都静默跳过，任何异常都不能影响
  /// 主流程（用户是来用 App 的，不是来看公告的）。
  ///
  /// **每次启动必弹**（2026-10-09）：`force: true` 无视已读/静默期，
  /// 只要后端配了匹配版本的公告就弹。[_annShownThisLaunch] 保证同一次
  /// 启动内只弹一次 —— 避免 initState 与后续调用重复弹两个遮罩。
  bool _annShownThisLaunch = false;

  Future<void> _checkAnnouncement() async {
    if (!mounted || _annShownThisLaunch) return;
    try {
      final svc = AnnouncementService(ref.read(sharedPreferencesProvider));
      final ann = await svc.fetchPending(version: kAppVersion, force: true);
      if (ann == null || !mounted) return;
      _annShownThisLaunch = true;
      AppLog.i('弹出公告：${ann.title}');
      await showAnnouncementDialog(context, ann);
    } catch (e) {
      // 公告是附加信息，失败不影响主流程——但要留痕，
      // 否则"后台建了公告用户说没弹"时无从判断是没配、没网还是抛异常。
      AppLog.w('拉取/展示公告失败', e);
    }
  }

  /// 启动时自动检查更新，发现新版本弹窗展示更新日志。
  /// 上次自动检查的时刻：回到前台时做 30 分钟节流，避免每次切回来都打
  /// 一轮网络（GitHub API 在国内不稳定，且启动还有其它任务在抢窗口）。
  DateTime? _lastUpdateCheck;

  /// 更新弹窗是否正在展示：防止 resume 与启动检查同时弹两个。
  bool _updateDialogOpen = false;

  /// 回到前台时补一次检查。
  ///
  /// 之前只在「启动 4 秒后」检查一次：应用常驻不关的话，之后发布的新版本
  /// 永远不会提示（2026-10-06 用户反馈「怎么不弹窗提示新版本」）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    // 云端 Agent 长任务续接（2026-10-11）：App 退后台/被杀期间任务在
    // forge 侧照常跑，回到前台把未完成的捞回来接着取，完成后消息自动
    // 补齐——这就是用户选定的「完成后通知」方式（App 内自动续接，
    // 不引入推送通道）。必须放在下面的 30 分钟限流之前：续接与更新
    // 检查频率无关，每次回前台都要试。
    unawaited(ref.read(chatProvider.notifier).resumeCloudTasks());

    final last = _lastUpdateCheck;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 30)) {
      return;
    }
    _autoCheckUpdate(delay: const Duration(seconds: 1));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 检查更新；[delay] 让启动路径避开启动高峰、resume 路径快速响应。
  Future<void> _autoCheckUpdate({
    Duration delay = const Duration(seconds: 4),
  }) async {
    if (_updateDialogOpen) return;
    _lastUpdateCheck = DateTime.now();
    await Future<void>.delayed(delay);
    // 延迟：首帧渲染 + 终端自启任务 + MCP 连接都在抢启动窗口，
    // 更新检查不与它们竞争。
    await Future<void>.delayed(const Duration(seconds: 4));
    try {
      final info = await ref.read(updateServiceProvider).checkForUpdate(
          kAppVersion,
          // Beta 用户：自动检查也走含预发布的通道（与关于页手动检查一致）
          includePrereleases: ref.read(betaOptInProvider));
      // 记一条"检查过且没有新版"——排查"为什么不弹更新"时，
      // 有这条才能排除"压根没发起检查"。
      AppLog.i(info == null
          ? '检查更新：已是最新版（v$kAppVersion）'
          : '检查更新：发现 ${info.version}');
      if (info == null || !mounted) return;
      ref.read(pendingUpdateProvider.notifier).state = info;
      if (!mounted) return;
      // 统一更新弹窗（截图样式）：弹窗内直接下载（进度条 + 实时速度），
      // 完成后自动拉起安装器；「稍后再说」随时可退出，下载中会取消。
      _updateDialogOpen = true;
      try {
        await UpdateDownloadDialog.show(context, info);
      } finally {
        _updateDialogOpen = false;
      }
    } catch (e) {
      // GitHub API 国内不稳定，失败很常见——记警告而非错误，
      // 免得日志里一片红把真正的故障淹了。
      AppLog.w('检查更新失败（不影响使用）', e);
    }
  }

  /// 执行并清空导航意图。
  ///
  /// 刻意【先清空再执行】：若在 ref.listen 回调里同步把意图置 null，
  /// 等于在 provider 的通知过程中再次写同一个 provider，
  /// 行为依赖 Riverpod 内部时序。先清空可确保无论监听何时触发都不会递归。
  void _consumeIntent() {
    final intent = ref.read(navIntentProvider);
    if (intent == null) return;
    // 先置空再改状态：setState 与写prefillProvider 都在之后
    ref.read(navIntentProvider.notifier).state = null;
    _applyIntent(intent);
  }

  void _applyIntent(NavIntent intent) {
    if (!mounted) return;
    if (intent.tab != _tab) {
      setState(() => _tab = intent.tab);
    }
    if (intent.prefill.isNotEmpty) {
      // 交给 ChatScreen 的输入框（它已在监听 prefillProvider）
      ref.read(prefillProvider.notifier).state = intent.prefill;
    }
  }

  /// 首次运行：检测终端环境，全部缺失时引导到下载向导页。
  Future<void> _maybeShowSetup() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool('terminal_setup_done') ?? false) return;
    try {
      final term = ref.read(terminalServiceProvider);
      var anyInstalled = false;
      for (final d in TerminalDistro.values) {
        if (await term.isInstalled(d)) anyInstalled = true;
      }
      if (!anyInstalled && mounted) {
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SetupScreen()));
      }
    } catch (_) {
      // 检测异常不阻塞应用使用
    } finally {
      await prefs.setBool('terminal_setup_done', true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 键盘弹起时把整棵子树顶上去。
    //
    // ⚠️ 避让只做一次（历史教训，截图对比竞品发现）：Scaffold 默认的
    // resizeToAvoidBottomInset = true 已经把 body 缩短一个键盘高度，
    // 这里若再手动 Padding(bottom: kb) 就顶了两次——内容被多抬高一个
    // 键盘的高度，表现为输入栏浮在屏幕顶端、与键盘之间一大片空白。
    // 必须显式设 resizeToAvoidBottomInset: false，把避让完全交给
    // 下面的手动 padding，键盘与输入栏才能贴合。
    final kb = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      // 必须用 scaffoldBg（= scaffoldBackgroundColor，页面底色）而不是
      // surface（卡片色）。Scaffold 的背景会铺满整个窗口，edge-to-edge 下
      // 状态栏那条区域也是它在画；用 surface 会出现「状态栏纯白 + 页面灰白」
      // 的色差带，看起来就像一条边。
      backgroundColor: scaffoldBg(context),
      drawer: SessionDrawer(
        // 抽屉底部「设置」图标直达「我的」Tab
        onGoTab: (t) {
          if (t != _tab) setState(() => _tab = t);
        },
      ),
      extendBody: true,
      // 显式关闭 Scaffold 自带的键盘避让（默认 true），键盘避让只由
      // body 外层的 Padding(bottom: kb) 做一次，否则双重避让会把
      // 输入栏顶到屏幕顶端（与键盘之间留下一整块空白）。
      resizeToAvoidBottomInset: false,
      body: Padding(
        padding: EdgeInsets.only(bottom: kb),
        child: IndexedStack(
          index: _tab,
          children: [
            const ChatScreen(),
            const TasksScreen(),
            SkillsScreen(onUseSkill: (text) {
              if (text.isNotEmpty) {
                ref.read(prefillProvider.notifier).state = text;
              }
              _goChat();
            }),
            const ProfileScreen(),
          ],
        ),
      ),
      // 底栏常驻（2026-10-10 结构性根治「导航栏卡死」）。
      //
      // 历史上这里用 AnimatedSize 在 kb>0 && typing 时把底栏折叠成 0 高度，
      // 配套了四道防线（isTopRoute 归属守卫、无焦点自愈、转场前 unfocus、
      // FocusManager 强制重建）——真机上仍会卡死重启才恢复，因为只要
      // viewInsets 与焦点同时停在「键盘开着」的旧值，任何信号都无法察觉
      // 系统键盘其实已经没了，纯 Dart 侧也没有独立的键盘可见性信号可查。
      //
      // 现在改为底栏永远渲染、不再折叠：
      // - App 是 edge-to-edge 全屏布局（main.dart SystemUiMode.edgeToEdge），
      //   键盘弹起时 IME 窗口物理覆盖屏幕底部——底栏在键盘后面本来就
      //   看不见，折叠只是视觉重复，去掉后打字时的观感完全一致；
      // - 键盘收起/卡死后，底栏始终钉在屏幕底部，不存在任何可以「卡住
      //   消失」的动画状态；四个信号（kb/焦点/路由/动画）全部与底栏
      //   显隐解耦，此 bug 类被结构性消灭。
      bottomNavigationBar: _FloatingGlassNavBar(
        index: _tab,
        height: _navHeight,
        // 与 HomeTab 常量保持一致：HomeShell 的 children 顺序即 Tab 顺序，
        // 两处都用常量，任一处调整顺序都会立刻暴露不一致。
        // onTap 闭包引用了 ref（刷新记忆计数），不能保持 const。
        onTap: (i) {
          setState(() => _tab = i);
          // Agent 在对话中可通过 save_memory 工具增删记忆，
          // IndexedStack 不重建子页，切到「我的」时强制刷新计数
          if (i == 3) ref.invalidate(memoryCountProvider);
        },
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem(this.icon, this.activeIcon, this.label);
}

const _navItems = <_NavItem>[
  _NavItem(Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, '对话'),
  _NavItem(Icons.alarm_outlined, Icons.alarm_on_outlined, '任务'),
  _NavItem(Icons.build_outlined, Icons.build_rounded, '技能'),
  _NavItem(Icons.person_outline_rounded, Icons.person_rounded, '我的'),
];

/// 悬浮液态玻璃底栏（2026-10-11）：
/// - 悬浮：四边留白、圆角胶囊造型，投影让它「漂」在内容之上；
///   extendBody 下页面内容从栏后穿过，磨砂实时模糊的就是底下内容，
///   液态玻璃的通透感来自这里。
/// - 液态玻璃：BackdropFilter 模糊 + 半透明表面渐变 + 左上高光sheen。
/// - 点击特效：按压缩放回弹（Listener+AnimatedScale）+ 水波纹
///   （InkWell）+ 选中项药丸高亮（AnimatedContainer）。
class _FloatingGlassNavBar extends StatelessWidget {
  const _FloatingGlassNavBar({
    required this.index,
    required this.onTap,
    required this.height,
  });

  final int index;
  final ValueChanged<int> onTap;
  final double height;

  static const _radius = 30.0;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      // 悬浮留白：左右与底部都不贴边，SafeArea 负责手势条以上的净空。
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      // 投影必须画在 ClipRRect 外面，否则会被裁掉。
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context)
                  .colorScheme
                  .shadow
                  .withValues(alpha: 0.16),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    surface(context).withValues(alpha: 0.80),
                    surface(context).withValues(alpha: 0.64),
                  ],
                ),
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(color: onSurface(context, 0.10)),
              ),
              // 玻璃高光：左上亮、右下微返光的液态质感。
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_radius),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.14),
                    Colors.white.withValues(alpha: 0.0),
                    Colors.white.withValues(alpha: 0.05),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: height,
                  child: Row(
                    children: [
                      for (var i = 0; i < _navItems.length; i++)
                        Expanded(
                          child: _NavTile(
                            item: _navItems[i],
                            selected: i == index,
                            primary: primary,
                            onTap: () => onTap(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个导航项：按压缩放回弹 + 水波纹 + 选中药丸高亮。
class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.item,
    required this.selected,
    required this.primary,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected
        ? widget.primary
        : onSurface(context, 0.38);
    // Listener 而非 GestureDetector：只读指针事件、不参与手势竞技场，
    // 与 InkWell 的 tap 互不干扰。
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: InkWell(
        onTap: () {
          // 触觉反馈（2026-10-11）：导航切换是高频关键交互，
          // 全项目此前零触觉反馈，从导航开始补。
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        borderRadius: BorderRadius.circular(22),
        splashColor: widget.primary.withValues(alpha: 0.10),
        highlightColor: widget.primary.withValues(alpha: 0.05),
        child: AnimatedScale(
          scale: _pressed ? 0.86 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: widget.selected
                  ? widget.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.selected ? widget.item.activeIcon : widget.item.icon,
                  size: 25,
                  color: color,
                ),
                const SizedBox(height: 2),
                Text(
                  widget.item.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
