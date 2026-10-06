import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'glass.dart';
import 'status_bar_area.dart';

import '../providers/providers.dart';
import '../services/database.dart';
import '../services/skill_service.dart';
import '../services/terminal_service.dart';

/// 技能 Tab：内置技能库（可一键安装）+ 我的快捷指令 + 内置工具展示。
///
/// 顶部「探索发现 / 技能」是两个可点击的视图切换按钮：
/// - 探索发现：内置技能库（分类 + 安装）
/// - 技能：我的快捷指令 + 内置工具（卡片可一键试用）
class SkillsScreen extends ConsumerStatefulWidget {
  const SkillsScreen({super.key, required this.onUseSkill});

  /// 参数为要预填到输入框的文本；空串表示仅跳转到对话页。
  final ValueChanged<String> onUseSkill;

  @override
  ConsumerState<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends ConsumerState<SkillsScreen> {
  String _category = '全部';

  /// 当前视图：false = 探索发现（内置技能库）；true = 技能（我的 + 工具）。
  bool _mineView = false;

  static const _categories = ['全部', '写作办公', '信息检索', '生活助手', '开发者工具'];

  /// 内置工具卡片：(emoji, 名称, 简介, 点击后预填的示例指令)。
  ///
  /// 示例指令要能直接触发对应工具——卡片不是摆设，点一下就到对话页
  /// 带着预填文本，用户按发送即可看到工具真实运行。
  static const _builtins = [
    ('🔍', '联网搜索', '实时检索网络信息，无需 API Key', '搜索一下今天的科技新闻'),
    ('🌐', '网页阅读', '抓取并总结任意网页内容', '帮我读取这个网页并总结要点：'),
    ('🧮', '精确计算', '四则运算、幂运算、括号表达式', '帮我精确计算：(1024*768+3600)/12^2'),
    ('🕐', '日期时间', '获取当前日期、星期与时间', '现在几点了？今天星期几？'),
    ('💡', '长期记忆', '记住你的偏好与重要信息', '请记住：我偏好简洁直接的表达方式'),
    ('📚', '知识库', '检索你导入的文档资料', '在知识库里检索与「项目计划」相关的内容'),
    ('💻', '终端命令', '在 Linux 沙箱里执行 shell 命令', '在终端环境里执行 uname -a 看看系统信息'),
  ];

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(skillServiceProvider);
    final skills = service.skills;

    final lib = builtinSkills
        .where((s) => _category == '全部' || s.category == _category)
        .toList();

    return Column(
      children: [
        // StatusBarArea 把状态栏那条区域也涂成页面底色（SafeArea 自身不画背景）
        StatusBarArea(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  // 顶部双标题 = 两个可点击的视图切换按钮。
                  _TitleButton(
                    label: '探索发现',
                    active: !_mineView,
                    onTap: () {
                      if (_mineView) setState(() => _mineView = false);
                    },
                  ),
                  const SizedBox(width: 16),
                  _TitleButton(
                    label: '技能',
                    active: _mineView,
                    onTap: () {
                      if (!_mineView) setState(() => _mineView = true);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
            children: [
              if (!_mineView) ...[
                // ================= 探索发现视图 =================
                Row(
                  children: [
                    const Text('内置技能库',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    const Spacer(),
                    Text('${builtinSkills.length} 个',
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.4))),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _installAll(context),
                      child: const Text('全部安装',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
                // 分类筛选
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final c in _categories)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _CategoryChip(
                            label: c,
                            selected: _category == c,
                            onTap: () => setState(() => _category = c),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ...lib.map((s) => _BuiltinSkillTile(
                      skill: s,
                      installed: service.isInstalled(s),
                      onInstall: () => _install(context, s),
                    )),
                const SizedBox(height: 16),
                Text('已安装的快捷指令在顶部「技能」页查看。',
                    style: TextStyle(
                        fontSize: 12, color: onSurface(context, 0.4))),
              ] else ...[
                // ================= 技能视图 =================
                // ------- 我的快捷指令 -------
                Row(
                  children: [
                    const Text('我的快捷指令',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _addSkill(context),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('新建',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
                Text('聊天输入「/名称 参数」即可触发，模板中的 {input} 会被参数替换。',
                    style: TextStyle(
                        fontSize: 12, color: onSurface(context, 0.4))),
                const SizedBox(height: 8),
                if (skills.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: surface(context),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text('还没有快捷指令。可以到「探索发现」里一键安装，\n'
                        '或点「新建」自己写一个，如：\n'
                        '名称「周报」，模板「帮我把以下工作内容整理成周报：{input}」',
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: onSurface(context, 0.45))),
                  )
                else
                  ...skills.map((s) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: surface(context),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          leading: const Icon(Icons.bolt_rounded),
                          title: Text('/${s.name}',
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w500)),
                          subtitle: Text(s.template,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => widget.onUseSkill('/${s.name} '),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => _deleteSkill(context, s),
                          ),
                        ),
                      )),
                const SizedBox(height: 16),

                // ------- 内置工具 -------
                const Text('内置工具',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text('点卡片预填示例指令，跳到对话页即可试用。',
                    style: TextStyle(
                        fontSize: 12, color: onSurface(context, 0.4))),
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
                    final (emoji, title, desc, sample) = _builtins[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(16),
                      // 预填一条能直接触发该工具的示例指令并跳到对话页，
                      // 卡片点得动、也用得上，而不是一个空跳转。
                      onTap: () => widget.onUseSkill(sample),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: surface(context),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: onSurface(context, 0.05),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: Text(emoji,
                                  style: const TextStyle(fontSize: 20)),
                            ),
                            const Spacer(),
                            Text(title,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 2),
                            Text(desc,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    height: 1.3,
                                    color: onSurface(context, 0.4))),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- 安装 ----------------

  /// 安装单个内置技能。依赖终端环境的技能在未安装时给出提示。
  Future<void> _install(BuildContext context, BuiltinSkill s) async {
    // 已安装：提示并询问是否卸载
    if (ref.read(skillServiceProvider).isInstalled(s)) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${s.name}」已安装，可在「技能」页的快捷指令中使用')));
      return;
    }

    // 终端类技能：环境未装好时先提醒（不阻断，仅告知）
    if (s.needsTerminal) {
      var ready = false;
      try {
        final term = ref.read(terminalServiceProvider);
        for (final d in TerminalDistro.values) {
          if (await term.isInstalled(d)) ready = true;
        }
      } catch (_) {}
      if (!ready && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('提示：该技能需要终端环境，请先到「我的 → 终端环境」安装')));
      }
    }

    final ok = await ref.read(skillServiceProvider).installBuiltin(s);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? '已安装「${s.name}」' : '「${s.name}」已存在，未重复安装')));
  }

  /// 批量安装内置技能。终端环境未就绪时跳过需要终端的技能，避免装了一堆跑不了。
  Future<void> _installAll(BuildContext context) async {
    var terminalReady = false;
    try {
      final term = ref.read(terminalServiceProvider);
      for (final d in TerminalDistro.values) {
        if (await term.isInstalled(d)) terminalReady = true;
      }
    } catch (_) {}

    final r = await ref
        .read(skillServiceProvider)
        .installAllBuiltins(skip: (s) => s.needsTerminal && !terminalReady);

    if (!context.mounted) return;
    final parts = <String>[];
    parts.add(r.added == 0 ? '没有新增技能' : '已安装 ${r.added} 个技能');
    if (r.skipped > 0) parts.add('跳过 ${r.skipped} 个（需先装终端环境）');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${parts.join('，')}。可在「技能」页的快捷指令中使用')));
  }

  Future<void> _addSkill(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final tmplCtrl = TextEditingController();
    // 双输入框弹窗（模板为多行），不迁移 showGlassTextDialog；输入值
    // 随 pop 带出 + whenComplete dispose（P2-6）。
    final saved = await showGlassDialog<(String, String)>(
      context: context,
      builder: (ctx) => glassAlertDialog(
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
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, (nameCtrl.text, tmplCtrl.text)),
              child: const Text('创建')),
        ],
      ),
    ).whenComplete(() {
      nameCtrl.dispose();
      tmplCtrl.dispose();
    });
    if (saved == null) return;
    final name = saved.$1.trim().replaceAll(RegExp(r'[\s/]'), '');
    final template = saved.$2.trim();
    if (name.isEmpty || template.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('名称和模板不能为空')));
      }
      return;
    }
    await ref.read(skillServiceProvider).addSkill(name, template);
  }

  Future<void> _deleteSkill(BuildContext context, SkillItem skill) async {
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => glassAlertDialog(
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

/// 顶部双标题按钮：激活项大而深色，非激活项小而浅色，点击切换视图。
class _TitleButton extends StatelessWidget {
  const _TitleButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Text(
          label,
          style: active
              ? const TextStyle(fontSize: 26, fontWeight: FontWeight.w500)
              : TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w500,
                  color: onSurface(context, 0.3)),
        ),
      ),
    );
  }
}

/// 分类筛选胶囊。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : surface(context),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: selected
                  ? Theme.of(context).colorScheme.onPrimary
                  : onSurface(context, 0.6),
            )),
      ),
    );
  }
}

/// 内置技能条目：图标 + 名称 + 简介 + 安装按钮（可展开看模板）。
class _BuiltinSkillTile extends StatefulWidget {
  const _BuiltinSkillTile({
    required this.skill,
    required this.installed,
    required this.onInstall,
  });

  final BuiltinSkill skill;
  final bool installed;
  final VoidCallback onInstall;

  @override
  State<_BuiltinSkillTile> createState() => _BuiltinSkillTileState();
}

class _BuiltinSkillTileState extends State<_BuiltinSkillTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.skill;
    final primary = Theme.of(context).colorScheme.primary;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: onSurface(context, 0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(s.emoji,
                        style: const TextStyle(fontSize: 20)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(s.name,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w500)),
                            const SizedBox(width: 6),
                            Text(s.category,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: onSurface(context, 0.35))),
                            if (s.needsTerminal) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.terminal_rounded,
                                  size: 13, color: onSurface(context, 0.35)),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(s.summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.35,
                                color: onSurface(context, 0.5))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  widget.installed
                      ? Padding(
                          padding: const EdgeInsets.only(top: 6, right: 6),
                          child: Row(
                            children: [
                              Icon(Icons.check_circle_rounded,
                                  size: 16, color: primary),
                              const SizedBox(width: 4),
                              Text('已安装',
                                  style: TextStyle(
                                      fontSize: 12, color: primary)),
                            ],
                          ),
                        )
                      : TextButton(
                          onPressed: widget.onInstall,
                          child: const Text('安装',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w500)),
                        ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: onSurface(context, 0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(s.template,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: onSurface(context, 0.6))),
            ),
        ],
      ),
    );
  }
}
