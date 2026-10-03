import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:characters/characters.dart';
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
  /// 播报世代号：每次 stopSpeaking 自增，用来作废所有在途的播报流程。
  /// 原实现用共享bool _cancelled，新一次 speak 会把它重置为 false，
  /// 于是上一段仍在合成/播放的流程"复活"，两段声音重叠；
  /// 且 _player 在 Process.start 的 await 之后才赋值，用户在那个窗口点停止
  /// 会杀不掉进程。现在每个流程携带自己的世代号，过期即自杀。
  int _generation = 0;

  bool get isListening => _listening;
  bool get isSpeaking => _speaking;

  // ---------------- ASR ----------------

  /// 初始化 ASR（首次调用触发麦克风权限请求）。不可用时返回 false。
  ///
  /// `onError` / `onStatus` 必须在这里传：`listen()` **不接受**这两个参数
  /// （只有 onResult / listenOptions 等）。且插件文档明确说明这两个回调
  /// 在首次 initialize 后**无法重置**，所以必须在此处一次性注册好。
  ///
  /// 不注册的话，配了 `cancelOnError: true` 后任何识别错误（静音超时、
  /// 权限被回收、音频通道被抢占）都会让底层自动停止，而 `_listening`
  /// 不会复位 —— UI 仍显示红色麦克风，用户得点两次才能恢复。
  Future<bool> ensureSpeech() async {
    if (_sttReady) return true;
    try {
      _sttReady = await _stt.initialize(
        onError: (e) {
          debugPrint('语音识别错误：${e.errorMsg}');
          _listening = false;
        },
        onStatus: (status) {
          // 识别自然结束 / 被取消时同步状态，否则 UI 与实际状态脱节
          if (status == SpeechToText.doneStatus ||
              status == SpeechToText.notListeningStatus) {
            _listening = false;
          }
        },
      );
    } catch (e) {
      debugPrint('语音识别初始化失败：$e');
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
    // 幂等：重复调用先停掉上一次，避免回调重复注册。
    if (_listening) await stopListening();
    _listening = true;
    // onError / onStatus 已在 ensureSpeech() → initialize() 时注册，
    // listen() 不接受这两个参数，且插件不允许 initialize 之后再重置。
    try {
      await _stt.listen(
        onResult: (r) {
          if (r.finalResult) _listening = false;
          onText(r.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          localeId: locale,
        ),
      );
    } catch (e) {
      _listening = false;
      debugPrint('启动语音识别失败：$e');
      return false;
    }
    return _listening;
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
    // 先无条件停掉上一段，再判断是否需要读。若反过来，空文本（纯代码块）
    // 会提前返回而不打断当前播放，用户听到的是上一条回答的音频，声画不同步。
    await stopSpeaking();
    if (plain.isEmpty) return;
    final gen = _generation;

    if (engine == TtsEngine.edge) {
      try {
        await _speakEdge(plain, edgeVoice, rate, volume, gen);
        return;
      } catch (e) {
        // 被新的一次 speak/stop 作废时不算失败，静默退出避免误回退系统 TTS
        if (gen != _generation) return;
        debugPrint('Edge TTS 失败，回退系统 TTS：$e');
      }
    }
    await _speakSystem(plain, rate, volume);
  }

  /// 停止播报（Edge 播放进程与系统 TTS 都停）。
  ///
  /// 自增世代号，作废所有在途的合成/播放流程。
  Future<void> stopSpeaking() async {
    _generation++;
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
      String text, String voice, double rate, double volume, int gen) async {
    final audio = await synthesizeEdge(
      text: text,
      voice: voice,
      rate: rate,
      volume: volume,
    );
    if (audio.isEmpty) throw Exception('Edge TTS 返回空音频');
    // 合成期间可能已被新的 speak/停止作废
    if (gen != _generation) return;

    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/tts');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File(
        '${dir.path}/edge_${DateTime.now().millisecondsSinceEpoch}.mp3');
    await file.writeAsBytes(audio, flush: true);

    // 写文件期间也可能被作废
    if (gen != _generation) {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      return;
    }

    _speaking = true;
    try {
      await _playAudio(file.path, gen);
    } finally {
      // 只有仍是当前世代才复位，避免过期流程把新流程的状态清掉
      if (gen == _generation) _speaking = false;
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
    // 同一次请求必须复用同一个 ConnectionId 与 X-Timestamp。
    // 原实现分别调用了两次 edgeConnectionId()，产生两个不同的随机 ID，
    // 服务端无法把两条日志关联到同一请求；两个 X-Timestamp 也跨越了
    // 潜在的手势握手，一致性校验可能失败。
    final connectionId = edgeConnectionId();
    final timestamp = edgeTimestamp();
    final url = Uri.parse('$_wsBase'
        '?TrustedClientToken=$trustedClientToken'
        '&Sec-MS-GEC=${edgeSecMsGec()}'
        '&Sec-MS-GEC-Version=1-$_chromiumFull'
        '&ConnectionId=$connectionId');

    final headers = {
      'Origin': _origin,
      'User-Agent': _userAgent,
      'Pragma': 'no-cache',
      'Cache-Control': 'no-cache',
    };

    // timeout 只中断「等待的 Future」，不会关闭正在进行的握手：
    // 握手超时后连接仍会建立完成且无人持有引用，反复超时累积 socket 直到
    // 达到 fd 上限。所以这里保留原始 Future，超时时补一次关闭。
    final connect = WebSocket.connect(url.toString(), headers: headers);
    final WebSocket ws;
    try {
      ws = await connect.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      // 连上了就立刻关掉；连不上则忽略（原始 Future 已完成并带错误）。
      unawaited(connect
          .then<void>((s) => s.close())
          .catchError((Object _) {}));
      rethrow;
    }

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

    ws.add(utf8.encode('X-Timestamp:$timestamp\r\n'
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

    ws.add(utf8.encode('X-RequestId:$connectionId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:$timestamp\r\n'
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
  ///
  /// [gen] 是本次播报的世代号：`Process.start` 是异步的，用户点「停止」可能
  /// 落在 await 与 `_player = p` 之间的窗口，此时 stopSpeaking() 杀不到进程，
  /// 音频会完整播完。启动后立刻校验世代号，过期就立即 kill 并放弃。
  Future<void> _playAudio(String path, int gen) async {
    const playTimeout = Duration(seconds: 120);
    for (final cmd in _playerCandidates(path)) {
      try {
        final exe = File(cmd.first);
        // 非绝对路径时交给 PATH 解析（ffplay 走终端环境）
        if (cmd.first.startsWith('/') && !exe.existsSync()) continue;
        final p = await Process.start(cmd.first, cmd.sublist(1));
        if (gen != _generation) {
          p.kill(ProcessSignal.sigkill);
          return;
        }
        _player = p;
        // 加超时：进程挂住时 await p.exitCode 永不返回，
        // 会导致 isSpeaking 永久为 true、临时 mp3 永不删除。
        final code = await p.exitCode.timeout(playTimeout, onTimeout: () {
          p.kill(ProcessSignal.sigkill);
          return -1;
        });
        if (gen != _generation) return;
        if (code == 0) return;
      } catch (_) {
        continue;
      }
    }
    throw Exception('无可用的音频播放器');
  }

  /// 播放器候选命令（抽成方法便于测试与复用）。
  static List<List<String>> _playerCandidates(String path) => [
        ['/system/bin/stagefright', path],
        ['/system/bin/toybox', 'play', path],
        ['ffplay', '-nodisp', '-autoexit', '-loglevel', 'quiet', path],
      ];

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
  // 注意：Dart 的 replaceAll 的替换串**不支持** $1 这类分组引用，
  // `r'$1'` 会被当成字面量写进结果（实测产出「标题。这是$1。。」）。
  // 要替换为捕获组必须用 replaceAllMapped。
  t = t.replaceAllMapped(
      RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1) ?? '');
  t = t.replaceAll(RegExp(r'[*_>~\[\]]'), '');
  t = t.replaceAll(RegExp(r'\n{2,}'), '。');
  t = t.trim();
  // 必须按字素簇截断：裸 substring(0, 400) 会劈开代理对（emoji、扩展汉字），
  // 产生孤立代理项。Dart 在 utf8.encode 时会把它静默替换成 U+FFFD，
  // 于是 Edge 音色念出来就是"�"，而用户会以为是音色配置不对。
  return t.characters.length > 400 ? t.characters.take(400).toString() : t;
}
