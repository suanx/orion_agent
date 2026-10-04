import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  final _addCtrl = TextEditingController();

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final memory = ref.watch(memoryServiceProvider);
    final notes = memory.notes;

    return Scaffold(
      appBar: AppBar(title: const Text('长期记忆')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addCtrl,
                    decoration: const InputDecoration(
                      hintText: '手动添加一条记忆，如：我喜欢简洁的回答',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.add),
                  onPressed: () async {
                    final text = _addCtrl.text.trim();
                    if (text.isEmpty) return;
                    await memory.addNote(text);
                    if (!mounted) return;
                    _addCtrl.clear();
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: notes.isEmpty
                ? const Center(
                    child: Text('暂无记忆。\n\nAgent 对话中调用 save_memory 工具\n'
                        '保存的信息会出现在这里。'),
                  )
                : ListView.builder(
                    itemCount: notes.length,
                    itemBuilder: (_, i) {
                      final n = notes[i];
                      return ListTile(
                        leading: const Icon(Icons.lightbulb_outline),
                        title: Text(n.text),
                        subtitle: Text(
                            '${n.createdAt.year}-${n.createdAt.month.toString().padLeft(2, '0')}-${n.createdAt.day.toString().padLeft(2, '0')}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await memory.removeNote(n.id);
                            if (!mounted) return;
                            setState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
