import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/llm_config.dart';
import '../providers/providers.dart';
import '../services/voice_service.dart';

/// 语音播报设置：开关 + 引擎 + 音色 + 语速 + 音量。
///
/// 全部写在 shared_preferences，聊天完成后由 ChatNotifier 读取生效。
class _TtsSettingsCard extends ConsumerStatefulWidget {
  const _TtsSettingsCard();

  @override
  ConsumerState<_TtsSettingsCard> createState() => _TtsSettingsCardState();
}

class _TtsSettingsCardState extends ConsumerState<_TtsSettingsCard> {
  bool _playing = false;

  Future<void> _preview() async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      await ref.read(voiceProvider).speak(
            '你好，我是 Pocket Agent，这是当前的播报音色。',
            engine: ref.read(ttsEngineProvider),
            edgeVoice: ref.read(ttsVoiceProvider),
            rate: ref.read(ttsRateProvider),
            volume: ref.read(ttsVolumeProvider),
          );
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(sharedPreferencesProvider);
    final on = prefs.getBool('tts_enabled') ?? false;
    final engine = ref.watch(ttsEngineProvider);
    final voice = ref.watch(ttsVoiceProvider);
    final rate = ref.watch(ttsRateProvider);
    final volume = ref.watch(ttsVolumeProvider);
    final isEdge = engine == TtsEngine.edge;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          decoration: BoxDecoration(
            color: surface(context),
            borderRadius: BorderRadius.circular(16),
          ),
          child: SwitchListTile(
            title: const Text('语音播报回答',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            subtitle: Text(
                isEdge ? '回答完成后用 Edge 在线语音朗读' : '回答完成后用系统语音朗读',
                style:
                    TextStyle(fontSize: 12, color: onSurface(context, 0.4))),
            value: on,
            onChanged: (v) {
              prefs.setBool('tts_enabled', v);
              setState(() {});
            },
          ),
        ),
        if (on)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('语音引擎',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(height: 10),
                SegmentedButton<TtsEngine>(
                  segments: const [
                    ButtonSegment(
                      value: TtsEngine.edge,
                      label: Text('Edge 语音'),
                      icon: Icon(Icons.cloud_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: TtsEngine.system,
                      label: Text('系统语音'),
                      icon: Icon(Icons.phone_android_rounded, size: 18),
                    ),
                  ],
                  selected: {engine},
                  showSelectedIcon: false,
                  // SegmentedButton 在某些交互下会给出空集合，直接 s.first 会抛
                  // StateError；空集合时忽略本次变更，保留原选择。
                  onSelectionChanged: (s) {
                    if (s.isEmpty) return;
                    prefs.setString('tts_engine', s.first.name);
                    ref.read(ttsEngineProvider.notifier).state = s.first;
                  },
                ),
                if (isEdge) ...[
                  const SizedBox(height: 16),
                  const Text('音色',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: edgeVoices
                        .map((v) => ChoiceChip(
                              label: Text(v.label),
                              selected: v.id == voice,
                              onSelected: (_) {
                                prefs.setString('tts_voice', v.id);
                                ref.read(ttsVoiceProvider.notifier).state = v.id;
                              },
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    voiceLabelOf(voice),
                    style: TextStyle(
                        fontSize: 12, color: onSurface(context, 0.4)),
                  ),
                ],
                const SizedBox(height: 16),
                _slider(
                  context,
                  label: '语速',
                  value: rate,
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  display: '${rate.toStringAsFixed(1)}x',
                  onChanged: (v) {
                    prefs.setDouble('tts_rate', v);
                    ref.read(ttsRateProvider.notifier).state = v;
                  },
                ),
                _slider(
                  context,
                  label: '音量',
                  value: volume,
                  min: 0.1,
                  max: 1.0,
                  divisions: 9,
                  display: '${(volume * 100).round()}%',
                  onChanged: (v) {
                    prefs.setDouble('tts_volume', v);
                    ref.read(ttsVolumeProvider.notifier).state = v;
                  },
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _playing ? null : _preview,
                    icon: Icon(_playing
                        ? Icons.hourglass_top_rounded
                        : Icons.play_arrow_rounded,
                        size: 18),
                    label: Text(_playing ? '播放中…' : '试听'),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Edge 语音由微软在线合成，无需 API Key；失败时自动回退系统语音。',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.35)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _slider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            const Spacer(),
            Text(display,
                style: TextStyle(fontSize: 12, color: onSurface(context, 0.45))),
          ],
        ),
        Slider(
          // clamp 在 double 上返回 num，需显式转回 double（Slider.value 要求 double）
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
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
          const _TtsSettingsCard(),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text('模型服务',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: onSurface(context, 0.5))),
          ),
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
