import 'package:flutter/material.dart';

/// 应用主题定义：Marvis 基础风格（浅灰底 + 白卡片）不变，切换主色。
class AppTheme {
  const AppTheme({required this.id, required this.name, required this.primary});

  final String id;
  final String name;
  final Color primary;
}

const List<AppTheme> appThemes = <AppTheme>[
  AppTheme(id: 'classic', name: '经典黑', primary: Colors.black),
  AppTheme(id: 'blue', name: '科技蓝', primary: Color(0xFF2563EB)),
  AppTheme(id: 'green', name: '松石绿', primary: Color(0xFF059669)),
  AppTheme(id: 'purple', name: '霓虹紫', primary: Color(0xFF7C3AED)),
  AppTheme(id: 'red', name: '珊瑚红', primary: Color(0xFFE11D48)),
  AppTheme(id: 'orange', name: '暖橙', primary: Color(0xFFEA580C)),
];

AppTheme themeById(String id) =>
    appThemes.firstWhere((t) => t.id == id, orElse: () => appThemes.first);

ThemeData buildAppTheme(AppTheme t) {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF6F6F6),
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: t.primary,
      onPrimary: Colors.white,
      surface: Colors.white,
    ),
    appBarTheme: AppBarTheme(
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
  );
}
