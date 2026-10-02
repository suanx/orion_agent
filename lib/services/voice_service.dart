import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音能力：系统 ASR 语音输入 + 系统 TTS 播报（无需额外 API Key）。
class VoiceService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _sttReady = false;
  bool _listening = false;

  bool get isListening => _listening;

  /// 初始化 ASR（首次调用触发麦克风权限请求）。不可用时返回 false。
  Future<bool> ensureSpeech() async {
    if (_sttReady) return true;
    try {
      _sttReady = await _stt.initialize();
    } catch (_) {
      _sttReady = false;
    }
    return _sttReady;
  }

  /// 开始聆听，识别结果（含中间结果）通过 onText 回调整段返回。
  Future<bool> startListening({
    required void Function(String text) onText,
    String locale = 'zh_CN',
  }) async {
    if (!await ensureSpeech()) return false;
    _listening = true;
    await _stt.listen(
      onResult: (r) => onText(r.recognizedWords),
      localeId: locale,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
      ),
    );
    return true;
  }

  Future<void> stopListening() async {
    _listening = false;
    try {
      await _stt.stop();
    } catch (_) {}
  }

  /// 朗读一段文本（过滤 markdown 后再读）。
  Future<void> speak(String text) async {
    final plain = stripMarkdownForSpeech(text);
    if (plain.isEmpty) return;
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(0.5);
      await _tts.stop();
      await _tts.speak(plain);
    } catch (_) {}
  }

  Future<void> stopSpeak() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

/// 为朗读做最小化 markdown 清理：代码块不读，去掉常见标记符号。
String stripMarkdownForSpeech(String s) {
  var t = s.replaceAll(RegExp(r'```[\s\S]*?```'), '（代码略）');
  t = t.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1) ?? '');
  t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'[*_>~\[\]]'), '');
  t = t.replaceAll(RegExp(r'\n{2,}'), '。');
  t = t.trim();
  return t.length > 400 ? '${t.substring(0, 400)}' : t;
}
