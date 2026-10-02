import 'package:flutter/material.dart';

/// 应用主题定义：浅色/深色共用一套主色板，深色下主色提亮保证对比度。
class AppTheme {
  const AppTheme({
    required this.id,
    required this.name,
    required this.primary,
    required this.darkPrimary,
  });

  final String id;
  final String name;
  final Color primary;
  final Color darkPrimary;
}

const List<AppTheme> appThemes = <AppTheme>[
  AppTheme(
      id: 'classic',
      name: '经典黑',
      primary: Colors.black,
      darkPrimary: Colors.white),
  AppTheme(
      id: 'blue',
      name: '科技蓝',
      primary: Color(0xFF2563EB),
      darkPrimary: Color(0xFF60A5FA)),
  AppTheme(
      id: 'green',
      name: '松石绿',
      primary: Color(0xFF059669),
      darkPrimary: Color(0xFF34D399)),
  AppTheme(
      id: 'purple',
      name: '霓虹紫',
      primary: Color(0xFF7C3AED),
      darkPrimary: Color(0xFFA78BFA)),
  AppTheme(
      id: 'red',
      name: '珊瑚红',
      primary: Color(0xFFE11D48),
      darkPrimary: Color(0xFFFB7185)),
  AppTheme(
      id: 'orange',
      name: '暖橙',
      primary: Color(0xFFEA580C),
      darkPrimary: Color(0xFFFB923C)),
];

AppTheme themeById(String id) =>
    appThemes.firstWhere((t) => t.id == id, orElse: () => appThemes.first);

/// 常用主题感知颜色快捷方式（深浅色自动适配）。
Color surface(BuildContext context) => Theme.of(context).colorScheme.surface;

Color onSurface(BuildContext context, double opacity) =>
    Theme.of(context).colorScheme.onSurface.withOpacity(opacity);

ThemeData buildAppTheme(AppTheme t, {bool dark = false}) {
  final primary = dark ? t.darkPrimary : t.primary;
  return ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor:
        dark ? const Color(0xFF101112) : const Color(0xFFF6F6F6),
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.primary,
      brightness: dark ? Brightness.dark : Brightness.light,
    ).copyWith(
      primary: primary,
      onPrimary: (dark && t.id == 'classic') ? Colors.black : Colors.white,
      surface: dark ? const Color(0xFF1B1C1E) : Colors.white,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: dark ? Colors.white : Colors.black,
      titleTextStyle: TextStyle(
        color: dark ? Colors.white : Colors.black,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    ),
    dividerColor: (dark ? Colors.white : Colors.black).withOpacity(0.06),
    splashFactory: InkSparkle.splashFactory,
  );
}
