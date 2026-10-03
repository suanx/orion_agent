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
            '你好，我是 Orion Agent，这是当前的播报音色。',
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
          // 配置持久化失败（Keystore 损坏 / 加密存储初始化失败）时，
          // 不提示的话用户会以为保存成功，重启后才发现配置全丢了。
          if (config.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Theme.of(context).colorScheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          config.error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
                  '填入 Base URL、API Key 和模型名即可。',
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
    // 不预填任何 Base URL：预填会让输入法弹出时自动带上「清除」按钮，
    // 用户第一眼看到的是一段可删的示例文本而不是输入框。
    final urlCtrl = TextEditingController(text: existing?.baseUrl ?? '');
    final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final modelCtrl = TextEditingController(text: existing?.model ?? '');
    double temperature = existing?.temperature ?? 0.7;
    var kind = existing?.kind ?? ModelKind.chat;
    final ctxCtrl = TextEditingController(
        text: (existing?.contextWindow ?? 0) <= 0 ? '' : '${existing!.contextWindow}');
    final outCtrl = TextEditingController(
        text: (existing?.maxOutputTokens ?? 0) <= 0 ? '' : '${existing!.maxOutputTokens}');

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // 表单会随类型切换增减字段，给一个最大高度并允许滚动，
      // 否则在键盘弹起 + 选了「向量模型」时底部字段会被裁掉。
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SingleChildScrollView(
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

              // 模型用途：聊天 / 向量。二者是不同的模型、不同的 API 路径，
              // 混在一个表单里会让用户不知道该填哪个字段。
              SegmentedButton<ModelKind>(
                segments: [
                  for (final k in ModelKind.values)
                    ButtonSegment(
                      value: k,
                      label: Text(k.label),
                      icon: Icon(k == ModelKind.chat
                          ? Icons.chat_bubble_outline
                          : Icons.gradient),
                    ),
                ],
                selected: {kind},
                onSelectionChanged: (s) => setSheetState(() => kind = s.first),
              ),
              const SizedBox(height: 4),
              Text(
                kind.hint,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(ctx).colorScheme.outline),
              ),
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
                decoration: InputDecoration(
                  labelText: kind == ModelKind.chat
                      ? '对话模型名（如 gpt-4o-mini、glm-4-flash）'
                      : '向量模型名（如 text-embedding-3-small、embedding-3）',
                ),
              ),

              // 上下文与输出长度：仅聊天模型有意义（向量模型没有上下文概念）
              if (kind == ModelKind.chat) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ctxCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '上下文长度（token）',
                          hintText: '如 128000，留空不限制',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: outCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '最大输出（token）',
                          hintText: '如 4096，留空不限制',
                        ),
                      ),
                    ),
                  ],
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
                        onChanged: (v) =>
                            setSheetState(() => temperature = v),
                      ),
                    ),
                  ],
                ),
              ],

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
    // token 数解析：留空或非法都按「不限制」处理，不弹错误打断配置流程。
    int parseTokens(String raw) => int.tryParse(raw.trim()) ?? 0;

    ref.read(configProvider.notifier).upsert(LlmConfig(
          id: existing?.id ?? 'cfg_${DateTime.now().millisecondsSinceEpoch}',
          name: nameCtrl.text.trim(),
          baseUrl: urlCtrl.text.trim(),
          apiKey: keyCtrl.text.trim(),
          model: modelCtrl.text.trim(),
          temperature: temperature,
          kind: kind,
          // 向量模型没有「上下文」概念，聊天模型沿用旧字段承载 embedding 名
          embeddingModel:
              kind == ModelKind.chat ? existing?.embeddingModel ?? '' : '',
          contextWindow: kind == ModelKind.chat ? parseTokens(ctxCtrl.text) : 0,
          maxOutputTokens:
              kind == ModelKind.chat ? parseTokens(outCtrl.text) : 0,
        ));
  }
}
