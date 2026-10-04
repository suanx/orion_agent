import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/chat_session.dart';
import 'providers/providers.dart';
import 'services/database.dart';
import 'services/memory_service.dart';
import 'services/navigation_service.dart';
import 'services/role_service.dart';
import 'services/skill_service.dart';
import 'services/storage_service.dart';
import 'services/terminal_service.dart';
import 'theme.dart';
import 'ui/home_shell.dart';

/// 开启沉浸式状态栏：内容延伸到状态栏与手势导航条下方。
///
/// - [SystemUiMode.edgeToEdge]：Android 10+ 全屏布局，状态栏/导航栏透明，
///   由各页面自己的 SafeArea 负责避让，视觉上内容铺满整屏。
/// - 图标亮度按当前明暗模式切换，保证浅色主题下状态栏图标是深色、可读。
/// - 使用 [SystemUiStyle.manual] 避免首帧（还是浅色主题）时图标闪烁。
void _applyImmersiveUI(Brightness brightness) {
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: SystemUiOverlay.values,
  );
  // 状态栏/导航栏保持透明，背景由 Flutter 侧的 Scaffold + StatusBarArea 提供。
  //
  // ⚠️ 两条必要条件，缺一个就会出现「状态栏一条黑边」：
  // 1. 这里 statusBarColor 必须是 transparent；
  // 2. **CI 不能往 styles.xml 注入 windowDrawsSystemBarBackgrounds=true**。
  //    那条属性把系统栏背景的绘制权交给 Android 框架，框架用主题默认值
  //    （不透明黑）绘制，并画在 Flutter 之上——上面这条 transparent
  //    会被完全架空，Flutter 里涂什么色都看不见。
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness:
        brightness == Brightness.dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: brightness,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness:
        brightness == Brightness.dark ? Brightness.light : Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  ));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();

  // 状态栏图标亮度按已保存的明暗设置决定，避免启动瞬间图标反色。
  _applyImmersiveUI(
      prefs.getString('theme_mode') == 'dark' ? Brightness.dark : Brightness.light);

  final db = AppDatabase();
  final storage = StorageService(db);
  // 会话数据是最常损坏的数据源（中途断电/磁盘满写半行），DB 故障时
  // 降级为空列表启动，避免 runApp 之前裸 await 造成永久白屏。
  List<ChatSession> sessions;
  try {
    sessions = await storage.loadSessions();
  } catch (e) {
    debugPrint('启动加载会话失败（${e.toString().split('\n').first}），已用空会话列表继续');
    sessions = const [];
  }
  final memory = MemoryService(db);
  final skills = SkillService(db);
  final roles = RoleService(db);

  // 这些 load() 都在 runApp 之前，任一抛异常都会让整个 App 起不来。
  // 各自的 load() 失败后已允许重试（不再用「已开始」语义的前置置位），
  // 这里降级为「先用空缓存启动」，避免数据层偶发故障直接阻断启动。
  Future<void> guard(String what, Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      debugPrint('启动预加载失败（$what），已用空数据继续：$e');
    }
  }

  await guard('长期记忆', memory.load);
  await guard('技能', skills.load);
  await guard('角色', roles.load);

  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    initialSessionsProvider.overrideWithValue(sessions),
    databaseProvider.overrideWithValue(db),
    memoryServiceProvider.overrideWithValue(memory),
    skillServiceProvider.overrideWithValue(skills),
    roleServiceProvider.overrideWithValue(roles),
  ]);

  // MCP 服务器后台连接（不阻塞启动），工具注册进 ToolRegistry
  unawaited(container.read(mcpServiceProvider).connectAll());

  // 本地通知：初始化渠道（不请求权限，权限由设置页显式触发）
  //
  // 必须在这里就传入 onTap：通知回调只注册一次，若用无参 init() 占位，
  // 之后再补的回调永远不会生效（init 内部对 _ready 短路）。
  // 用户点通知 → 写入导航意图；冷启动时 runApp 还没跑，
  // 意图会先记在 provider 里，HomeShell 首帧后再执行。
  unawaited(container.read(notificationServiceProvider).init(
        onTap: (payload) {
          debugPrint('notification tapped: $payload');
          container.read(navigationServiceProvider).handlePayload(payload);
        },
      ));

  // 自启动任务：环境就绪的在后台拉起（不阻塞启动）
  unawaited(container
      .read(terminalServiceProvider)
      .autostartTasks(TerminalTask.decodeList(prefs.getString(
          TerminalService.tasksPrefsKey))));

  // 自动任务调度：补跑错过的每天任务 + 存活期每分钟 tick（不阻塞启动）。
  // 注意：无系统级后台能力，App 进程被杀则调度停止，
  // 错过的任务在下次启动时补跑（见 TasksNotifier._catchUpMissed）。
  unawaited(container.read(tasksProvider.notifier).start());

  runApp(UncontrolledProviderScope(
    container: container,
    child: const OrionAgentApp(),
  ));
}

class OrionAgentApp extends ConsumerWidget {
  const OrionAgentApp({super.key});

  /// 明暗模式 → 状态栏图标亮度（浅色底用深色图标）。
  static Brightness _iconBrightness(ThemeMode mode, Brightness platform) {
    switch (mode) {
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.system:
        return platform;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = themeById(ref.watch(themeProvider));
    final mode = ref.watch(themeModeProvider);

    // 用户切换明暗模式时同步状态栏/导航栏图标，保持可读。
    _applyImmersiveUI(_iconBrightness(mode, MediaQuery.platformBrightnessOf(context)));

    return MaterialApp(
      title: 'Orion Agent',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(accent),
      darkTheme: buildAppTheme(accent, dark: true),
      themeMode: mode,
      home: const HomeShell(),
    );
  }
}
