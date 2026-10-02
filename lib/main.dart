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

class PocketAgentApp extends StatelessWidget {
  const PocketAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pocket Agent',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF6F6F6),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          brightness: Brightness.light,
        ).copyWith(
          primary: Colors.black,
          onPrimary: Colors.white,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.black,
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        dividerColor: Colors.black.withOpacity(0.06),
        splashFactory: InkSparkle.splashFactory,
      ),
      home: const HomeShell(),
    );
  }
}
