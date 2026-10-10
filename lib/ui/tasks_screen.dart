import '../theme.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'glass.dart';
import 'status_bar_area.dart';

import '../providers/providers.dart';
import '../services/database.dart';

/// 任务 Tab：自动任务（定时 / 手动触发的 Agent 提示词）。
///
/// 功能：
/// - 新建 / 编辑 / 删除任务（emoji + 名称 + 提示词 + 每天定时或手动）
/// - 手动立即运行；每天任务由调度器自动运行（App 存活期每分钟 tick，
///   错过的在启动时补跑）
/// - 运行结果写回任务卡片，点开可看；完成后发系统通知
class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  /// 示例任务（空列表时展示，点一下直接进入预填好的编辑器）。
  static const _samples = <(String, String, String)>[
    ('📰', '今日科技要闻', '请联网搜索今天的科技要闻，整理成 5 条一句话摘要。'),
    ('🌤️', '每日天气播报', '查询我所在城市今天的天气，给出穿衣与出行建议。'),
    ('💰', '汇率速览', '查询美元、欧元、日元兑人民币的最新汇率并简要点评。'),
    ('🏃', '运动打卡提醒', '用一句话提醒我今天的运动目标，并给我一个 10 分钟拉伸动作清单。'),
    ('📚', '每日一词', '教我一个实用的商务英语词汇，给出释义、例句和记忆技巧。'),
    ('📈', '关注标的行情', '联网查询今天 A 股大盘行情，给出涨跌幅与一句话点评。'),
  ];

  @override
  void initState() {
    super.initState();
    // 页面首次进入即加载（调度器在 main 已启动，这里保证列表新鲜）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tasksProvider.notifier).load();
    });
  }

  Future<void> _openEditor({TaskRow? existing, (String, String, String)? preset}) async {
    final saved = await showGlassDialog<bool>(
      context: context,
      builder: (_) => _TaskEditor(existing: existing, preset: preset),
    );
    if (saved == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('任务已保存')));
      }
    }
  }

  Future<void> _delete(TaskRow t) async {
    // 先捕获 notifier（P2-9）：await 之后 ref 可能已随 State 销毁不可用，
    // 但删除动作本身仍应执行。
    final notifier = ref.read(tasksProvider.notifier);
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: Text('删除「${t.name}」？'),
        content: const Text('运行结果也会一并删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(color: Color(0xFFD93025)))),
        ],
      ),
    );
    if (ok != true) return;
    await notifier.remove(t.id);
  }

  Future<void> _run(TaskRow t) async {
    final ok = await ref.read(tasksProvider.notifier).run(t.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? '「${t.name}」运行完成' : '「${t.name}」运行失败，点开卡片查看原因')));
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(tasksProvider).tasks;
    final running = ref.watch(tasksProvider).runningIds;

    return Column(
      children: [
        // ------- 顶栏 -------
        StatusBarArea(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('自动任务',
                        style: TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: '新建任务',
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: () => _openEditor(),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? _buildEmpty(context)
              : _buildList(context, tasks, running),
        ),
        SizedBox(height: tasks.isEmpty ? 64 : 72),
      ],
    );
  }

  // ---------------- 空状态 ----------------

  Widget _buildEmpty(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      children: [
        const SizedBox(height: 48),
        Center(
          child: Text('开启你的第一个自动任务吧',
              style: const TextStyle(
                  fontSize: 21, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text('让 Agent 定时替你跑搜索、看行情、做汇总',
              style: TextStyle(fontSize: 13, color: onSurface(context, 0.45))),
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton.icon(
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('新建自动任务',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            style: FilledButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 15),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28)),
            ),
          ),
        ),
        const SizedBox(height: 36),
        Text('从示例开始（点一下即可创建）',
            style: TextStyle(fontSize: 13, color: onSurface(context, 0.4))),
        const SizedBox(height: 10),
        for (final (emoji, title, prompt) in _samples)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openEditor(preset: (emoji, title, prompt)),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(
                  color: surface(context),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Text(emoji, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 2),
                          Text(prompt,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: onSurface(context, 0.4))),
                        ],
                      ),
                    ),
                    Icon(Icons.add_rounded,
                        size: 18, color: onSurface(context, 0.35)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---------------- 列表 ----------------

  Widget _buildList(
      BuildContext context, List<TaskRow> tasks, Set<String> running) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      children: [
        for (final t in tasks)
          _TaskCard(
            // key 按任务 id（2026-10-11 P1）：_TaskCard 是 StatefulWidget
            // （持有折叠展开态），无 key 时删除中间一项，Element 按位置
            // 复用，展开态会「跳」到另一张卡片上。
            key: ValueKey(t.id),
            task: t,
            running: running.contains(t.id),
            onRun: () => _run(t),
            onEdit: () => _openEditor(existing: t),
            onDelete: () => _delete(t),
            onToggle: (v) async {
              await ref.read(tasksProvider.notifier).upsert(
                    t.copyWith(enabled: v),
                  );
            },
          ),
      ],
    );
  }
}

// ---------------- 任务卡片 ----------------

class _TaskCard extends StatefulWidget {
  const _TaskCard({
    required this.task,
    required this.running,
    required this.onRun,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  final TaskRow task;
  final bool running;
  final VoidCallback onRun;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _expanded = false;

  String get _scheduleLabel {
    final t = widget.task;
    if (t.scheduleType != 'daily' || t.scheduleHour == null) return '非定时';
    final hh = t.scheduleHour.toString().padLeft(2, '0');
    final mm = (t.scheduleMinute ?? 0).toString().padLeft(2, '0');
    return '每天 $hh:$mm';
  }

  String? get _lastRunLabel {
    final t = widget.task;
    if (t.lastRunAt == null) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(t.lastRunAt!);
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(d.month)}-${p2(d.day)} ${p2(d.hour)}:${p2(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final hasResult = t.lastResult != null && t.lastResult!.isNotEmpty;
    final failed = t.lastStatus == 'fail';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: hasResult ? () => setState(() => _expanded = !_expanded) : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: surface(context),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text(t.emoji, style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(t.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500)),
                            ),
                            const SizedBox(width: 6),
                            Text(_scheduleLabel,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: onSurface(context, 0.35))),
                          ],
                        ),
                        if (hasResult) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(
                                failed
                                    ? Icons.error_outline_rounded
                                    : Icons.check_circle_outline_rounded,
                                size: 13,
                                color: failed
                                    ? const Color(0xFFD93025)
                                    : const Color(0xFF188038),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${_lastRunLabel ?? ''} · ${t.lastResult!.replaceAll('\n', ' ')}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: onSurface(context, 0.4)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 立即运行 / 运行中
                  widget.running
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child:
                              CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : IconButton(
                          tooltip: '立即运行',
                          icon: const Icon(Icons.play_arrow_rounded, size: 26),
                          onPressed: widget.onRun,
                        ),
                  // 启用开关
                  Switch(value: t.enabled, onChanged: widget.onToggle),
                ],
              ),
              if (_expanded && hasResult) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: onSurface(context, 0.04),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(t.lastResult!,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: onSurface(context, 0.7))),
                ),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: widget.onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('编辑', style: TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('删除', style: TextStyle(fontSize: 13)),
                  ),
                  const Spacer(),
                  if (hasResult)
                    TextButton(
                      onPressed: () =>
                          setState(() => _expanded = !_expanded),
                      child: Text(_expanded ? '收起结果' : '查看结果',
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 新建 / 编辑对话框 ----------------

/// 任务编辑弹窗。返回 true 表示已保存。
class _TaskEditor extends StatefulWidget {
  const _TaskEditor({this.existing, this.preset});

  final TaskRow? existing;

  /// 空状态示例卡片预填（emoji, name, prompt）。
  final (String, String, String)? preset;

  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  static const _emojiChoices = [
    '⏰', '📰', '🌤️', '💰', '🏃', '📚', '📈', '🔍', '🧘', '🍳', '💻', '✨',
  ];

  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late String _emoji;
  late bool _daily;
  int _hour = 8;
  int _minute = 0;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? widget.preset?.$2 ?? '');
    _prompt = TextEditingController(text: e?.prompt ?? widget.preset?.$3 ?? '');
    _emoji = e?.emoji ?? widget.preset?.$1 ?? '⏰';
    _daily = e?.scheduleType == 'daily';
    _hour = e?.scheduleHour ?? 8;
    _minute = e?.scheduleMinute ?? 0;
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _hour, minute: _minute),
    );
    if (t != null) {
      setState(() {
        _hour = t.hour;
        _minute = t.minute;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // _save 需要 ref：包一层 Consumer 拿到。
    return Consumer(builder: (context, ref, _) {
      Future<void> save() async {
        final name = _name.text.trim();
        final prompt = _prompt.text.trim();
        if (name.isEmpty || prompt.isEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('名称和提示词不能为空')));
          return;
        }
        final e = widget.existing;
        final row = e == null
            ? TaskRow(
                id: uniqueId('task'),
                emoji: _emoji,
                name: name,
                prompt: prompt,
                scheduleType: _daily ? 'daily' : 'manual',
                scheduleHour: _daily ? _hour : null,
                scheduleMinute: _daily ? _minute : null,
                enabled: true,
                createdAt: DateTime.now().millisecondsSinceEpoch,
              )
        // 不用 drift 的 copyWith：可空列（scheduleHour 等）的参数类型是
        // Value<int?>（absent 表示保留），直接全量构造更直白。
        : TaskRow(
            id: e.id,
            emoji: _emoji,
            name: name,
            prompt: prompt,
            scheduleType: _daily ? 'daily' : 'manual',
            scheduleHour: _daily ? _hour : null,
            scheduleMinute: _daily ? _minute : null,
            enabled: e.enabled,
            lastRunAt: e.lastRunAt,
            lastStatus: e.lastStatus,
            lastResult: e.lastResult,
            createdAt: e.createdAt,
          );
        // 必须先捕获 notifier 再 pop：pop 会销毁对话框 Consumer，
        // 其 ref 在 unmount 后不可再用（Riverpod 会抛断言）。
        final notifier = ref.read(tasksProvider.notifier);
        Navigator.pop(context, true);
        await notifier.upsert(row);
      }

      return glassAlertDialog(
        title: Text(widget.existing == null ? '新建自动任务' : '编辑任务'),
        content: SizedBox(
          width: double.maxFinite,
          // 同 storage_settings：Column 替代嵌套 shrinkWrap ListView，
          // 避免「弹窗内容无法滑动」的手势抢占问题
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // emoji 选择
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final e in _emojiChoices)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(e, style: const TextStyle(fontSize: 17)),
                          selected: _emoji == e,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() => _emoji = e),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                autofocus: widget.existing == null && widget.preset == null,
                decoration: const InputDecoration(
                  labelText: '任务名称',
                  hintText: '如：每日科技要闻',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _prompt,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '提示词（Agent 收到后会自动调工具完成）',
                  hintText: '如：联网搜索今天的科技要闻，整理成 5 条摘要',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('手动运行')),
                  ButtonSegment(value: true, label: Text('每天定时')),
                ],
                selected: {_daily},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _daily = s.first),
              ),
              if (_daily)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_rounded),
                  title: Text('每天 '
                      '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}'),
                  trailing: const Icon(Icons.edit_outlined, size: 18),
                  onTap: _pickTime,
                ),
              if (_daily) ...[
                Text('说明：App 在运行状态时准点执行；若当时 App 已关闭，'
                    '下次打开会自动补跑当天错过的任务。',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: onSurface(context, 0.4))),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(onPressed: save, child: const Text('保存')),
        ],
      );
    });
  }
}
