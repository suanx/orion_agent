import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/voice_service.dart';
import '../theme.dart';

/// 语音播报设置页。
///
/// 独立成页：原先是挂在「模型设置」里的，而那个页面已改为
/// 「AI 提供商」列表（一个提供商 = 一组模型），语音播报与它无关，
/// 混在一起会让页面主题不清晰。
class TtsSettingsScreen extends StatelessWidget {
  const TtsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('语音播报')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: const [TtsSettingsCard()],
      ),
    );
  }
}

/// 语音播报设置：开关 + 引擎 + 音色 + 语速 + 音量。
///
/// 全部写在 shared_preferences，聊天完成后由 ChatNotifier 读取生效。
class TtsSettingsCard extends ConsumerStatefulWidget {
  const TtsSettingsCard({super.key});

  @override
  ConsumerState<TtsSettingsCard> createState() =>
      _TtsSettingsCardState();
}

class _TtsSettingsCardState extends ConsumerState<TtsSettingsCard> {
  bool _playing = false;
  /// 试听后从 VoiceService.lastError 读出的失败原因。
  /// Edge 失败会回退系统 TTS，若系统 TTS 也不可用，之前界面毫无反馈，
  /// 用户只能看到「播放中…」卡住，完全无从排查。
  String? _error;

  Future<void> _preview() async {
    if (_playing) return;
    setState(() {
      _playing = true;
      _error = null;
    });
    try {
      await ref.read(voiceProvider).speak(
            '你好，我是 Orion Agent，这是当前的播报音色。',
            engine: ref.read(ttsEngineProvider),
            edgeVoice: ref.read(ttsVoiceProvider),
            rate: ref.read(ttsRateProvider),
            volume: ref.read(ttsVolumeProvider),
          );
    } finally {
      if (mounted) {
        setState(() {
          _playing = false;
          _error = ref.read(voiceProvider).lastError;
        });
      }
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
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _error!,
                      style: TextStyle(
                          fontSize: 12, color: Colors.red.shade400),
                    ),
                  ),
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
