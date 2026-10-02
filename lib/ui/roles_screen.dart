import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/database.dart';

/// Agent 角色管理：人设列表、新建/编辑/删除、切换当前角色。
class RolesScreen extends ConsumerWidget {
  const RolesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roles = ref.watch(roleServiceProvider).roles;
    final activeId = ref.watch(activeRoleIdProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Agent 角色')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editRole(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('新建角色'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 80),
        children: [
          ListTile(
            leading: Icon(
              activeId.isEmpty
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color:
                  activeId.isEmpty ? Theme.of(context).colorScheme.primary : null,
            ),
            title: const Text('默认助手',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            subtitle: Text('通用智能助手，无人设限定',
                style: TextStyle(
                    fontSize: 12, color: onSurface(context, 0.4))),
            onTap: () => ref.read(activeRoleIdProvider.notifier).state = '',
          ),
          const Divider(height: 1),
          ...roles.map((r) => ListTile(
                leading: Icon(
                  r.id == activeId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: r.id == activeId
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(r.name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500)),
                subtitle: Text(r.prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: onSurface(context, 0.4))),
                onTap: () =>
                    ref.read(activeRoleIdProvider.notifier).state = r.id,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => _editRole(context, ref, r),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () async {
                        if (ref.read(activeRoleIdProvider) == r.id) {
                          ref.read(activeRoleIdProvider.notifier).state = '';
                        }
                        await ref.read(roleServiceProvider).removeRole(r.id);
                      },
                    ),
                  ],
                ),
              )),
          if (roles.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('还没有自定义角色。\n\n'
                  '角色是一段附加的人设指令，例如「你是严谨的技术翻译，'
                  '只输出译文，不解释」。切换后对所有对话生效。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      height: 1.5, color: onSurface(context, 0.45))),
            ),
        ],
      ),
    );
  }

  Future<void> _editRole(
      BuildContext context, WidgetRef ref, AgentRole? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final promptCtrl = TextEditingController(text: existing?.prompt ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '新建角色' : '编辑角色'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '角色名（如：技术翻译）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: promptCtrl,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '人设指令',
                hintText: '如：你只输出译文，不解释，保留代码原样',
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
              child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    final name = nameCtrl.text.trim();
    final prompt = promptCtrl.text.trim();
    if (name.isEmpty || prompt.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('角色名和人设不能为空')));
      }
      return;
    }
    final service = ref.read(roleServiceProvider);
    if (existing == null) {
      await service.addRole(name, prompt);
    } else {
      await service.updateRole(existing.id, name, prompt);
    }
  }
}
