import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// 技能 Tab：展示当前可用的内置工具。
class SkillsScreen extends ConsumerWidget {
  const SkillsScreen({super.key, required this.onUseSkill});

  final VoidCallback onUseSkill;

  static const _skills = [
    ('🔍', '联网搜索', '实时检索网络信息，无需 API Key'),
    ('🌐', '网页阅读', '抓取并总结任意网页内容'),
    ('🧮', '精确计算', '四则运算、幂运算、括号表达式'),
    ('🕐', '日期时间', '获取当前日期、星期与时间'),
    ('💡', '长期记忆', '记住你的偏好与重要信息'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 读取一次 registry 以保证工具已注册（当前列表为静态展示）
    ref.watch(toolRegistryProvider);

    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              children: [
                const Text('探索发现',
                    style:
                        TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                const SizedBox(width: 16),
                Text('技能',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(0.3))),
              ],
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.95,
            ),
            itemCount: _skills.length,
            itemBuilder: (_, i) {
              final (emoji, title, desc) = _skills[i];
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('到对话页发送任务即可使用「$title」')));
                  onUseSkill();
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Text(emoji, style: const TextStyle(fontSize: 22)),
                      ),
                      const Spacer(),
                      Text(title,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(desc,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: Colors.black.withOpacity(0.4))),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
