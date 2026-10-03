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
    Theme.of(context).colorScheme.onSurface.withValues(alpha: opacity);

/// 页面底色（= Scaffold 的背景色）。
///
/// edge-to-edge 下需要自己给状态栏区域涂背景时用它——它与
/// `scaffoldBackgroundColor` 一致，所以涂上去看不出接缝。
/// 不要用 [surface]：那是卡片色，比页面底色略深，涂在状态栏上
/// 会出现一条色差。
Color scaffoldBg(BuildContext context) =>
    Theme.of(context).scaffoldBackgroundColor;

/// 吉祥物素材：深色模式用深底版本，浅色模式用白底版本。
String mascotAsset(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? 'assets/images/mascot_dark.webp'
        : 'assets/images/mascot.webp';

/// 圆形吉祥物头像。
///
/// 原实现用 [ClipOval] + [Transform.scale] 硬裁，把方图放大 1.6 倍后裁成圆，
/// 结果只剩一张大脸、看不到围巾和身体，视觉上又大又怪。
/// 这里改为「整图等比缩放 + 白底/深底圆形容器」，
/// 完整保留吉祥物的头、围巾和身体，并统一各处的尺寸与留白。
class MascotAvatar extends StatelessWidget {
  const MascotAvatar({super.key, required this.size, required this.image});

  /// 头像直径。
  final double size;

  /// 素材路径（由 [mascotAsset] 按明暗模式给出）。
  final String image;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Image.asset(
          image,
          fit: BoxFit.cover,
          cacheWidth: (size * 3).round(),
          errorBuilder: (_, __, ___) => ColoredBox(
            color: surface(context),
            child: Icon(Icons.smart_toy_outlined,
                size: size * 0.55, color: onSurface(context, 0.4)),
          ),
        ),
      ),
    );
  }
}

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
      // 不能用transparent：edge-to-edge 下状态栏区域会透出窗口底色
      // （Android 上是黑边）。各页面都用 SafeArea 把 AppBar 下移了，
      // 状态栏那条区域本身没有 widget 去涂背景，所以必须由 AppBar 自己填。
      backgroundColor: dark ? const Color(0xFF101112) : const Color(0xFFF6F6F6),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: dark ? Colors.white : Colors.black,
      titleTextStyle: TextStyle(
        color: dark ? Colors.white : Colors.black,
        fontSize: 18,
        fontWeight: FontWeight.w500,
      ),
    ),
    dividerColor: (dark ? Colors.white : Colors.black).withValues(alpha: 0.06),
    splashFactory: InkSparkle.splashFactory,
  );
}
