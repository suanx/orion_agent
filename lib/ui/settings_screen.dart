import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/llm_config.dart';
import '../providers/providers.dart';

/// 语音播报开关（写在 shared_preferences，聊天完成后生效）。
class _TtsToggle extends ConsumerStatefulWidget {
  const _TtsToggle();

  @override
  ConsumerState<_TtsToggle> createState() => _TtsToggleState();
}

class _TtsToggleState extends ConsumerState<_TtsToggle> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(sharedPreferencesProvider);
    final on = prefs.getBool('tts_enabled') ?? false;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SwitchListTile(
        title: const Text('语音播报回答',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        subtitle: Text('回答完成后用系统语音朗读',
            style: TextStyle(
                fontSize: 12, color: Colors.black.withOpacity(0.4))),
        value: on,
        onChanged: (v) {
          prefs.setBool('tts_enabled', v);
          setState(() {});
        },
      ),
    );
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型设置'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editConfig(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('添加模型服务'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          const _TtsToggle(),
          if (config.configs.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没有配置模型服务。\n\n'
                  '支持任何 OpenAI 兼容接口：\n'
                  '填入 Base URL、API Key 和模型名即可。\n\n'
                  '例如：\n'
                  'https://api.openai.com/v1\n'
                  'https://open.bigmodel.cn/api/paas/v4\n'
                  'https://api.deepseek.com/v1',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ...config.configs.map((c) {
              final active = c.id == config.activeConfig?.id;
              return ListTile(
                leading: Icon(
                  active ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: active ? Theme.of(context).colorScheme.primary : null,
                ),
                title: Text(c.name.isEmpty ? c.model : c.name),
                subtitle: Text('${c.model}\n${c.baseUrl}'),
                isThreeLine: true,
                onTap: () => ref.read(configProvider.notifier).setActive(c.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _editConfig(context, ref, c),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          ref.read(configProvider.notifier).remove(c.id),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Future<void> _editConfig(
      BuildContext context, WidgetRef ref, LlmConfig? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl =
        TextEditingController(text: existing?.baseUrl ?? 'https://api.openai.com/v1');
    final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final modelCtrl = TextEditingController(text: existing?.model ?? '');
    final embCtrl = TextEditingController(text: existing?.embeddingModel ?? '');
    double temperature = existing?.temperature ?? 0.7;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(existing == null ? '添加模型服务' : '编辑模型服务',
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                    labelText: '名称（如 OpenAI、GLM、DeepSeek）'),
              ),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                    labelText: 'Base URL（OpenAI 兼容，以 /v1 结尾）'),
              ),
              TextField(
                controller: keyCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API Key'),
              ),
              TextField(
                controller: modelCtrl,
                decoration: const InputDecoration(
                    labelText: '模型名（如 gpt-4o-mini、glm-4-flash）'),
              ),
              TextField(
                controller: embCtrl,
                decoration: const InputDecoration(
                  labelText: 'Embedding 模型名（可选，用于知识库检索）',
                  hintText: '如 text-embedding-3-small、embedding-3',
                ),
              ),
              Row(
                children: [
                  const Text('温度'),
                  Expanded(
                    child: Slider(
                      value: temperature,
                      min: 0,
                      max: 1.5,
                      divisions: 15,
                      label: temperature.toStringAsFixed(1),
                      onChanged: (v) => setSheetState(() => temperature = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );

    if (saved != true) return;
    if (urlCtrl.text.trim().isEmpty || modelCtrl.text.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Base URL 和模型名不能为空')));
      }
      return;
    }
    ref.read(configProvider.notifier).upsert(LlmConfig(
          id: existing?.id ?? 'cfg_${DateTime.now().millisecondsSinceEpoch}',
          name: nameCtrl.text.trim(),
          baseUrl: urlCtrl.text.trim(),
          apiKey: keyCtrl.text.trim(),
          model: modelCtrl.text.trim(),
          temperature: temperature,
          embeddingModel: embCtrl.text.trim(),
        ));
  }
}
