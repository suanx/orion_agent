import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/skill_service.dart';

/// 技能 Tab：内置工具展示 + 我的快捷指令（提示词模板）管理。
class SkillsScreen extends ConsumerWidget {
  const SkillsScreen({super.key, required this.onUseSkill});

  /// 参数为要预填到输入框的文本；空串表示仅跳转到对话页。
  final ValueChanged<String> onUseSkill;

  static const _builtins = [
    ('🔍', '联网搜索', '实时检索网络信息，无需 API Key'),
    ('🌐', '网页阅读', '抓取并总结任意网页内容'),
    ('🧮', '精确计算', '四则运算、幂运算、括号表达式'),
    ('🕐', '日期时间', '获取当前日期、星期与时间'),
    ('💡', '长期记忆', '记住你的偏好与重要信息'),
    ('📚', '知识库', '检索你导入的文档资料'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skills = ref.watch(skillServiceProvider).skills;

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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
            children: [
              // ------- 我的快捷指令 -------
              Row(
                children: [
                  const Text('我的快捷指令',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _addSkill(context, ref),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('新建',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              Text('聊天输入「/名称 参数」即可触发，模板中的 {input} 会被参数替换。',
                  style: TextStyle(
                      fontSize: 12, color: Colors.black.withOpacity(0.4))),
              const SizedBox(height: 8),
              if (skills.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text('还没有快捷指令，点「新建」创建一个，如：\n'
                      '名称「周报」，模板「帮我把以下工作内容整理成周报：{input}」',
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Colors.black.withOpacity(0.45))),
                )
              else
                ...skills.map((s) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        leading: const Icon(Icons.bolt_rounded),
                        title: Text('/${s.name}',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        subtitle: Text(s.template,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => onUseSkill('/${s.name} '),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _deleteSkill(context, ref, s),
                        ),
                      ),
                    )),
              const SizedBox(height: 16),
              // ------- 内置工具 -------
              const Text('内置工具',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.15,
                ),
                itemCount: _builtins.length,
                itemBuilder: (_, i) {
                  final (emoji, title, desc) = _builtins[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => onUseSkill(''),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child:
                                Text(emoji, style: const TextStyle(fontSize: 20)),
                          ),
                          const Spacer(),
                          Text(title,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(desc,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  height: 1.3,
                                  color: Colors.black.withOpacity(0.4))),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addSkill(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final tmplCtrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建快捷指令'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration:
                  const InputDecoration(labelText: '名称（聊天时输入 /名称）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tmplCtrl,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '提示词模板',
                hintText: '如：帮我把以下内容整理成周报：{input}',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('创建')),
        ],
      ),
    );
    if (saved != true) return;
    final name = nameCtrl.text.trim().replaceAll(RegExp(r'[\s/]'), '');
    final template = tmplCtrl.text.trim();
    if (name.isEmpty || template.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('名称和模板不能为空')));
      }
      return;
    }
    await ref.read(skillServiceProvider).addSkill(name, template);
  }

  Future<void> _deleteSkill(
      BuildContext context, WidgetRef ref, SkillItem skill) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${skill.name}」？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Color(0xFFD93025)))),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(skillServiceProvider).removeSkill(skill.id);
    }
  }
}
