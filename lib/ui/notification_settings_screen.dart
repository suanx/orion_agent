import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// 通知设置：回答完成提醒、内容预览、静音、权限申请。
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen> {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    _refreshPermission();
  }

  Future<void> _refreshPermission() async {
    final ok = await ref.read(notificationServiceProvider).hasPermission();
    if (mounted) setState(() => _granted = ok);
  }

  void _save(String key, Object value) {
    final prefs = ref.read(sharedPreferencesProvider);
    if (value is bool) {
      prefs.setBool(key, value);
    } else if (value is double) {
      prefs.setDouble(key, value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onAnswer = ref.watch(notifyOnAnswerProvider);
    final preview = ref.watch(notifyPreviewProvider);
    final silent = ref.watch(notifySilentProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // ------- 权限状态 -------
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  _granted == true
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_rounded,
                  size: 20,
                  color: _granted == true
                      ? Theme.of(context).colorScheme.primary
                      : onSurface(context, 0.35),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _granted == null
                        ? '正在检查通知权限…'
                        : (_granted! ? '通知权限已开启' : '通知权限未开启'),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                if (_granted == false)
                  TextButton(
                    onPressed: () async {
                      await ref
                          .read(notificationServiceProvider)
                          .requestPermission();
                      await _refreshPermission();
                    },
                    child: const Text('授权'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          _label('提醒'),
          _card([
            SwitchListTile(
              title: const Text('回答完成后通知',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              subtitle: Text('切到后台或锁屏时也能收到提醒',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.4))),
              value: onAnswer,
              onChanged: (v) async {
                _save('notify_on_answer', v);
                ref.read(notifyOnAnswerProvider.notifier).state = v;
                if (v) {
                  await ref.read(notificationServiceProvider).requestPermission();
                  await _refreshPermission();
                }
                setState(() {});
              },
            ),
          ]),
          const SizedBox(height: 20),

          _label('内容'),
          _card([
            SwitchListTile(
              title: const Text('显示回答摘要',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              subtitle: Text('关闭后通知只显示「已生成回答」，更注重隐私',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.4))),
              value: preview,
              onChanged: onAnswer
                  ? (v) {
                      _save('notify_preview', v);
                      ref.read(notifyPreviewProvider.notifier).state = v;
                      setState(() {});
                    }
                  : null,
            ),
            Divider(height: 1, color: onSurface(context, 0.06)),
            SwitchListTile(
              title: const Text('静音通知',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              subtitle: Text('仅横幅提示，不响铃不震动',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.4))),
              value: silent,
              onChanged: onAnswer
                  ? (v) {
                      _save('notify_silent', v);
                      ref.read(notifySilentProvider.notifier).state = v;
                      setState(() {});
                    }
                  : null,
            ),
          ]),
          const SizedBox(height: 20),

          _label('测试'),
          _card([
            ListTile(
              title: const Text('发送测试通知',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              subtitle: Text('确认在当前机型上能正常弹出',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.4))),
              trailing: const Icon(Icons.send_rounded, size: 18),
              onTap: () async {
                final svc = ref.read(notificationServiceProvider);
                await svc.requestPermission();
                await svc.notifyTaskDone(
                  title: 'Orion Agent 测试通知',
                  detail: '如果你看到了这条消息，说明通知已正常工作。',
                  silent: silent,
                );
                await _refreshPermission();
              },
            ),
          ]),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '全部为本地通知，不上传任何内容到服务器。'
              '部分机型需要在系统设置里允许「自启动」或关闭电池优化，'
              '后台通知才能稳定送达。',
              style: TextStyle(
                  fontSize: 12, height: 1.5, color: onSurface(context, 0.4)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
        child: Text(t,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: onSurface(context, 0.45))),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: surface(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(children: children),
      );
}
