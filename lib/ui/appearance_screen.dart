import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// 外观设置页：主题配色 + 明暗模式。
///
/// 原本这两块直接钉在「我的」页顶部，占掉首屏、且和列表内容混在一起。
/// 现在收进独立页面，由「我的 → 外观主题」入口进入。
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(sharedPreferencesProvider);
    final currentTheme = ref.watch(themeProvider);

    void pickTheme(String id) {
      prefs.setString('theme_id', id);
      ref.read(themeProvider.notifier).state = id;
    }

    void pickMode(String mode) {
      prefs.setString('theme_mode', mode);
      ref.read(themeModeProvider.notifier).state = mode == 'light'
          ? ThemeMode.light
          : (mode == 'dark' ? ThemeMode.dark : ThemeMode.system);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('外观主题')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _SectionLabel('主题配色'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final t in appThemes)
                  _ThemeSwatch(
                    theme: t,
                    selected: currentTheme == t.id,
                    onTap: () => pickTheme(t.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _SectionLabel('明暗模式'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'system',
                      label: Text('跟随系统'),
                      icon: Icon(Icons.brightness_auto_rounded, size: 18)),
                  ButtonSegment(
                      value: 'light',
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode_rounded, size: 18)),
                  ButtonSegment(
                      value: 'dark',
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode_rounded, size: 18)),
                ],
                selected: {ref.watch(themeModeProvider).name},
                showSelectedIcon: false,
                onSelectionChanged: (s) => pickMode(s.first),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '配色与明暗模式立即生效，并保存在本机。',
              style: TextStyle(fontSize: 12, color: onSurface(context, 0.4)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
      child: Text(text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: onSurface(context, 0.45),
          )),
    );
  }
}

/// 单个配色项：色块 + 名称 + 选中描边。
class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final AppTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.primary,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : onSurface(context, 0.08),
                  width: selected ? 2 : 1,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded,
                      size: 20, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(theme.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  color: selected ? onSurface(context, 1) : onSurface(context, 0.55),
                )),
          ],
        ),
      ),
    );
  }
}
