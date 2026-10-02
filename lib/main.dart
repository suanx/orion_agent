import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers/providers.dart';
import 'services/database.dart';
import 'services/memory_service.dart';
import 'services/role_service.dart';
import 'services/skill_service.dart';
import 'services/storage_service.dart';
import 'theme.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final db = AppDatabase();
  final sessions = await StorageService(db).loadSessions();
  final memory = MemoryService(db);
  await memory.load();
  final skills = SkillService(db);
  await skills.load();
  final roles = RoleService(db);
  await roles.load();

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

  runApp(UncontrolledProviderScope(
    container: container,
    child: const PocketAgentApp(),
  ));
}

class PocketAgentApp extends ConsumerWidget {
  const PocketAgentApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = buildAppTheme(themeById(ref.watch(themeProvider)));
    return MaterialApp(
      title: 'Pocket Agent',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: theme,
      home: const HomeShell(),
    );
  }
}
