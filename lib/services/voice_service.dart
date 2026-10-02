import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音合成引擎。
enum TtsEngine {
  /// 微软 Edge 在线合成（免 API Key），音色自然、支持多音色。
  edge,

  /// 系统内置 TTS（离线可用，音色取决于系统）。
  system,
}

/// Edge TTS 音色（zh-CN）。
class EdgeVoice {
  const EdgeVoice(this.id, this.label, this.gender);

  final String id;
  final String label;
  final String gender;
}

/// 可选音色列表。id 与 Edge 合成接口的 SSML voice name 一致。
const List<EdgeVoice> edgeVoices = [
  EdgeVoice('zh-CN-XiaoxiaoNeural', '晓晓 · 女 · 温柔', '女'),
  EdgeVoice('zh-CN-XiaoyiNeural', '晓伊 · 女 · 活泼', '女'),
  EdgeVoice('zh-CN-YunxiNeural', '云希 · 男 · 阳光', '男'),
  EdgeVoice('zh-CN-YunyangNeural', '云扬 · 男 · 播报', '男'),
  EdgeVoice('zh-CN-YunjianNeural', '云健 · 男 · 沉稳', '男'),
  EdgeVoice('zh-CN-liaoning-XiaobeiNeural', '晓北 · 女 · 东北', '女'),
  EdgeVoice('zh-CN-shaanxi-XiaoniNeural', '晓妮 · 女 · 陕西', '女'),
];

/// 按音色 id 取展示名；找不到时回退到首个音色的名字。
String voiceLabelOf(String id) {
  for (final v in edgeVoices) {
    if (v.id == id) return v.label;
  }
  return edgeVoices.first.label;
}

/// 语音能力：系统 ASR 语音输入 + 语音播报（Edge TTS / 系统 TTS）。
///
/// Edge TTS 走微软「大声朗读」的 WebSocket 合成接口，**无需 API Key**。
/// 该接口需要 Sec-MS-GEC 签名（见 [edgeSecMsGec]）与较新的 Chromium UA，
/// 二者缺失都会被服务端以 403 拒绝。
class VoiceService {
  VoiceService();

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _sttReady = false;
  bool _listening = false;

  /// 当前播放进程，用于打断播报。
  Process? _player;
  bool _speaking = false;
  bool _cancelled = false;

  bool get isListening => _listening;
  bool get isSpeaking => _speaking;

  // ---------------- ASR ----------------

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

  // ---------------- TTS ----------------

  /// 朗读一段文本（过滤 markdown 后再读）。
  ///
  /// [engine] 为 [TtsEngine.edge] 时走 Edge 在线合成；
  /// 合成或播放失败**自动回退系统 TTS**，保证任何情况下都能出声。
  Future<void> speak(
    String text, {
    TtsEngine engine = TtsEngine.edge,
    String edgeVoice = 'zh-CN-XiaoxiaoNeural',
    double rate = 1.0,
    double volume = 1.0,
  }) async {
    final plain = stripMarkdownForSpeech(text);
    if (plain.isEmpty) return;
    await stopSpeaking();
    _cancelled = false;

    if (engine == TtsEngine.edge) {
      try {
        await _speakEdge(plain, edgeVoice, rate, volume);
        return;
      } catch (e) {
        debugPrint('Edge TTS 失败，回退系统 TTS：$e');
      }
    }
    await _speakSystem(plain, rate, volume);
  }

  /// 停止播报（Edge 播放进程与系统 TTS 都停）。
  Future<void> stopSpeaking() async {
    _cancelled = true;
    try {
      _player?.kill();
    } catch (_) {}
    _player = null;
    _speaking = false;
    try {
      await _tts.stop();
    } catch (_) {}
  }

  // ---------------- Edge TTS ----------------

  /// Edge「大声朗读」的 WebSocket 端点（免鉴权，仅需 TrustedClientToken）。
  static const _wsBase =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';

  /// Edge 公开的 TrustedClientToken，用于免登录调用合成接口。
  static const trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  /// 必须声明的 Chromium 版本。服务端按 UA 校验客户端新旧，
  /// 过旧（实测 131 及以下）直接 403，140+ 可通过。
  static const chromiumVersion = '143';
  static const _chromiumFull = '143.0.3650.75';

  /// Windows FILETIME 与 Unix 纪元的秒差（1601-01-01 → 1970-01-01）。
  static const _winEpochSeconds = 11644473600;

  static const _origin =
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';

  static String get _userAgent =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/$_chromiumFull Safari/537.36 '
      'Edg/$_chromiumFull';

  Future<void> _speakEdge(
      String text, String voice, double rate, double volume) async {
    final audio = await synthesizeEdge(
      text: text,
      voice: voice,
      rate: rate,
      volume: volume,
    );
    if (audio.isEmpty) throw Exception('Edge TTS 返回空音频');
    if (_cancelled) return;

    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/tts');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File(
        '${dir.path}/edge_${DateTime.now().millisecondsSinceEpoch}.mp3');
    await file.writeAsBytes(audio, flush: true);

    _speaking = true;
    try {
      await _playAudio(file.path);
    } finally {
      _speaking = false;
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  /// 走 Edge 的 WebSocket 合成，返回 MP3 字节。公开出来便于单元测试。
  Future<Uint8List> synthesizeEdge({
    required String text,
    String voice = 'zh-CN-XiaoxiaoNeural',
    double rate = 1.0,
    double volume = 1.0,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final url = Uri.parse('$_wsBase'
        '?TrustedClientToken=$trustedClientToken'
        '&Sec-MS-GEC=${edgeSecMsGec()}'
        '&Sec-MS-GEC-Version=1-$_chromiumFull'
        '&ConnectionId=${edgeConnectionId()}');

    final ws = await WebSocket.connect(
      url.toString(),
      headers: {
        'Origin': _origin,
        'User-Agent': _userAgent,
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
      },
    ).timeout(const Duration(seconds: 15));

    final audio = BytesBuilder(copy: false);
    final done = Completer<void>();

    final sub = ws.listen(
      (dynamic raw) {
        if (raw is! List<int>) return;
        final bytes = Uint8List.fromList(raw);
        // 音频与结束标记都在**二进制帧**里：
        // 前 2 字节 = 头长度（大端），随后是头文本，剩余部分才是负载。
        final parsed = parseEdgeFrame(bytes);
        if (parsed == null) return;
        if (parsed.isAudio) {
          audio.add(parsed.payload);
        } else if (parsed.isTurnEnd) {
          if (!done.isCompleted) done.complete();
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    ws.add(utf8.encode('X-Timestamp:${edgeTimestamp()}\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}'));

    // Edge 的语速/音量用百分比增量表达
    final ratePct = ((rate - 1.0) * 100).round();
    final volPct = ((volume - 1.0) * 100).round();
    final ssml = '<speak version="1.0" '
        'xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="zh-CN">'
        '<voice name="$voice">'
        '<prosody rate="${ratePct >= 0 ? '+' : ''}$ratePct%" '
        'volume="${volPct >= 0 ? '+' : ''}$volPct%" pitch="+0Hz">'
        '${escapeXml(text)}</prosody></voice></speak>';

    ws.add(utf8.encode('X-RequestId:${edgeConnectionId()}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${edgeTimestamp()}\r\n'
        'Path:ssml\r\n\r\n$ssml'));

    try {
      await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
      try {
        await ws.close();
      } catch (_) {}
    }
    return audio.takeBytes();
  }

  /// 播放 MP3。Android 侧优先用系统 stagefright 播放器，
  /// 该路径无需额外依赖；不可用时抛出，由调用方回退系统 TTS。
  Future<void> _playAudio(String path) async {
    final candidates = <List<String>>[
      ['/system/bin/stagefright', path],
      ['/system/bin/toybox', 'play', path],
      ['ffplay', '-nodisp', '-autoexit', '-loglevel', 'quiet', path],
    ];
    for (final cmd in candidates) {
      try {
        final exe = File(cmd.first);
        // 非绝对路径时交给 PATH 解析（ffplay 走终端环境）
        if (cmd.first.startsWith('/') && !exe.existsSync()) continue;
        final p = await Process.start(cmd.first, cmd.sublist(1));
        _player = p;
        final code = await p.exitCode;
        if (code == 0) return;
      } catch (_) {
        continue;
      }
    }
    throw Exception('无可用的音频播放器');
  }

  Future<void> _speakSystem(String plain, double rate, double volume) async {
    try {
      await _tts.setLanguage('zh-CN');
      // flutter_tts 的 rate 是 0.0~1.0 平台相关量，0.5 约等于正常语速。
      // clamp 在 double 上返回 num，需 toDouble() 才能匹配 setSpeechRate(double)。
      await _tts.setSpeechRate((0.5 * rate).clamp(0.05, 1.0).toDouble());
      await _tts.setVolume(volume.clamp(0.0, 1.0).toDouble());
      await _tts.stop();
      await _tts.speak(plain);
    } catch (_) {}
  }
}

// ---------------- Edge TTS 协议工具（纯函数，便于单测） ----------------

/// Edge 合成结果的一帧。
class EdgeFrame {
  const EdgeFrame({required this.header, required this.payload});

  final String header;
  final Uint8List payload;

  bool get isAudio => header.contains('Path:audio');
  bool get isTurnEnd => header.contains('Path:turn.end');
}

/// 解析 Edge 的二进制帧：前 2 字节为头长度（大端），随后是头文本，
/// 剩余部分为负载（音频帧的负载即 MP3 数据）。
///
/// 头长度非法或超出帧长时返回 null（丢弃该帧而不是抛异常）。
EdgeFrame? parseEdgeFrame(Uint8List bytes) {
  if (bytes.length < 2) return null;
  final headerLen = (bytes[0] << 8) | bytes[1];
  if (headerLen <= 0 || 2 + headerLen > bytes.length) return null;
  final header = latin1.decode(
    bytes.sublist(2, 2 + headerLen),
    allowInvalid: true,
  );
  return EdgeFrame(
    header: header,
    payload: Uint8List.sublistView(bytes, 2 + headerLen),
  );
}

/// 计算 Sec-MS-GEC 签名。
///
/// 算法：把当前时间转成 Windows FILETIME（100ns 间隔，1601 起算），
/// 向下圆整到 5 分钟（3,000,000,000 × 100ns），再取
/// `SHA256(ticks + TrustedClientToken)` 的大写十六进制。
/// 签名有效期约 5 分钟。
String edgeSecMsGec({DateTime? now}) {
  final t = (now ?? DateTime.now()).toUtc();
  final seconds = t.millisecondsSinceEpoch / 1000 + VoiceService._winEpochSeconds;
  var ticks = (seconds * 10000000).floor();
  ticks -= ticks % 3000000000;
  final raw = '$ticks${VoiceService.trustedClientToken}';
  return sha256.convert(utf8.encode(raw)).toString().toUpperCase();
}

/// Edge 协议里的时间戳：UTC 的 `yyyy-MM-ddTHH:mm:ss.fffZ`。
String edgeTimestamp({DateTime? now}) {
  final t = (now ?? DateTime.now()).toUtc();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${t.year}-${p(t.month)}-${p(t.day)}T'
      '${p(t.hour)}:${p(t.minute)}:${p(t.second)}'
      '.${p(t.millisecond, 3)}Z';
}

/// 生成 Edge 协议用的随机 ConnectionId（32 位十六进制）。
String edgeConnectionId([math.Random? random]) {
  final r = random ?? math.Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
}

/// SSML 文本转义。
String escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 为朗读做最小化 markdown 清理：代码块不读，去掉常见标记符号。
String stripMarkdownForSpeech(String s) {
  var t = s.replaceAll(RegExp(r'```[\s\S]*?```'), '（代码略）');
  t = t.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1) ?? '');
  t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1');
  t = t.replaceAll(RegExp(r'[*_>~\[\]]'), '');
  t = t.replaceAll(RegExp(r'\n{2,}'), '。');
  t = t.trim();
  return t.length > 400 ? '${t.substring(0, 400)}' : t;
}
