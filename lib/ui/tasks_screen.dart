import '../theme.dart';
import 'package:flutter/material.dart';

/// 任务 Tab（M3 功能的占位页，风格与设计稿一致）。
class TasksScreen extends StatelessWidget {
  const TasksScreen({super.key});

  static const _samples = [
    ('💻', '今日科技要闻速览'),
    ('📚', '快速学一个商务英语词汇'),
    ('🔍', '冷知识盲盒'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ------- 顶栏 -------
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('自动任务',
                    style:
                        TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                          color: Color(0xFF3B82F6), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 5),
                    Text('我的手机',
                        style: TextStyle(
                            fontSize: 13,
                            color: onSurface(context, 0.4))),
                    Icon(Icons.keyboard_arrow_down_rounded,
                        size: 16, color: onSurface(context, 0.4)),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              const Spacer(flex: 3),
              const Text('开启你的第一个自动任务吧',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('自动任务将在 M3 版本上线，敬请期待')),
                ),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 15),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, color: Theme.of(context).colorScheme.onPrimary, size: 20),
                      SizedBox(width: 6),
                      Text('新建自动任务',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
              const Spacer(flex: 2),
              // ------- 示例任务卡片 -------
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  children: [
                    for (final (emoji, title) in _samples)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 16),
                          decoration: BoxDecoration(
                            color: surface(context),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              Text(emoji, style: const TextStyle(fontSize: 20)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(title,
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                              ),
                              Text('非定时',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: onSurface(context, 0.35))),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 64),
      ],
    );
  }
}
