import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// 对话字体设置页：四档预设字号缩放。
///
/// 档位定义与 chatFontScaleProvider 的取值一一对应；
/// 上方预览区用当前选中档位实时渲染一段示例对话，所见即所得。
/// 选择立即生效并持久化到 SharedPreferences（key: chat_font_scale）。
class FontSettingsScreen extends ConsumerWidget {
  const FontSettingsScreen({super.key});

  /// 档位表：缩放系数 → 显示名。
  /// 顺序即 UI 呈现顺序；新增档位时同步 providers.dart 的注释约定。
  static const _options = <double, String>{
    0.85: '小',
    1.0: '标准',
    1.15: '大',
    1.3: '特大',
  };

  static String labelOf(double scale) => _options[scale] ?? '标准';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(chatFontScaleProvider);

    void pick(double s) {
      ref.read(sharedPreferencesProvider).setDouble('chat_font_scale', s);
      ref.read(chatFontScaleProvider.notifier).state = s;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('对话字体')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // ------- 预览区：用选中档位实时渲染 -------
          _PreviewCard(scale: scale),
          const SizedBox(height: 20),
          _SectionLabel('字号'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<double>(
                segments: [
                  for (final e in _options.entries)
                    ButtonSegment(
                      value: e.key,
                      label: Text(e.value),
                    ),
                ],
                selected: {scale},
                showSelectedIcon: false,
                // 空集合时忽略，避免 s.first 抛 StateError（与外观页同一约定）
                onSelectionChanged: (s) {
                  if (s.isEmpty) return;
                  pick(s.first);
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '仅调整对话内容（气泡 / 正文 / 思考面板）的文字大小，顶栏与输入栏保持标准字号。设置立即生效并保存在本机。',
              style: TextStyle(fontSize: 12, color: onSurface(context, 0.4)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 预览卡：一段缩放的示例对话（用户气泡 + 助手正文）。
///
/// 直接用 TextScaler.linear 仿照 chat_screen 消息区的实现方式，
/// 保证预览效果与真实对话一致。
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.scale});

  final double scale;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bodyScale = TextStyle(
      fontSize: 14.5 * scale,
      height: 1.55,
      color: onSurface(context, 0.92),
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text('帮我总结一下今天的日程',
                  style: TextStyle(fontSize: 14 * scale)),
            ),
          ),
          const SizedBox(height: 12),
          Text('你今天有 3 项安排：上午 10 点的周会、下午 2 点的代码评审，'
              '以及晚间 8 点的健身计划。周会需要提前准备进度汇报。',
              style: bodyScale),
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
