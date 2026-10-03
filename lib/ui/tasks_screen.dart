import '../theme.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'status_bar_area.dart';

/// 任务 Tab（M3 功能的占位页，风格与设计稿一致）。
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {

  /// 示例任务候选池。每次进入随机抽 [_sampleCount] 条，
  /// 避免每次进来都是同一组。
  static const _allSamples = <(String, String)>[
    ('💻', '今日科技要闻速览'),
    ('📚', '快速学一个商务英语词汇'),
    ('🔍', '冷知识盲盒'),
    ('🌤️', '每天早晨天气播报'),
    ('💰', '记账提醒与月度汇总'),
    ('🏃', '每日运动打卡提醒'),
    ('📈', '关注的股票行情速览'),
    ('🎧', '每日一首爵士乐推荐'),
    ('🧘', '冥想计时与呼吸练习'),
    ('🍳', '今晚吃什么：随机菜谱'),
    ('📷', '城市街拍灵感收集'),
    ('🌱', '阳台种菜注意事项'),
  ];

  /// 示例卡片展示条数。
  static const _sampleCount = 4;

  /// 从候选池随机抽 [_sampleCount] 条（Fisher-Yates 部分洗牌）。
  List<(String, String)> _pickSamples() {
    final pool = List<(String, String)>.of(_allSamples);
    final rnd = math.Random();
    final n = _sampleCount.clamp(0, pool.length);
    for (var i = 0; i < n; i++) {
      final j = i + rnd.nextInt(pool.length - i);
      final tmp = pool[i];
      pool[i] = pool[j];
      pool[j] = tmp;
    }
    return pool.sublist(0, n);
  }

  /// 抽一次存起来。放build 里每次重抽会让卡片在
  /// 键盘弹起等 rebuild 场景下突然重排。
  late final List<(String, String)> _samples;

  @override
  void initState() {
    super.initState();
    _samples = _pickSamples();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ------- 顶栏 -------
        // StatusBarArea 把状态栏那条区域也涂成页面底色（SafeArea 自身不画背景）
        StatusBarArea(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('自动任务',
                      style:
                          TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
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
        ),
        Expanded(
          child: Column(
            children: [
              const Spacer(flex: 3),
              const Text('开启你的第一个自动任务吧',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
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
                              fontWeight: FontWeight.w500)),
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
                                        fontWeight: FontWeight.w500)),
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
