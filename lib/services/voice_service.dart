import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:audioplayers/audioplayers.dart';
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
  /// MP3 播放器（audioplayers，底层 ExoPlayer/MediaPlayer）。
  final AudioPlayer _audio = AudioPlayer();
  bool _speaking = false;
  /// 最近一次播报失败的错误（合成/播放/系统 TTS 任一层），供 UI 展示。
  /// 每次 speak 开头清空；成功播完保持 null。
  String? lastError;
  /// 播报世代号：每次 stopSpeaking 自增，用来作废所有在途的播报流程。
  /// 原实现用共享bool _cancelled，新一次 speak 会把它重置为 false，
  /// 于是上一段仍在合成/播放的流程"复活"，两段声音重叠；
  /// 且播放器在异步启动完成后才登记，用户在那个窗口点停止
  /// 会停不掉。现在每个流程携带自己的世代号，过期即自杀。
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
    lastError = null;

    if (engine == TtsEngine.edge) {
      try {
        await _speakEdge(plain, edgeVoice, rate, volume, gen);
        return;
      } catch (e) {
        // 被新的一次 speak/stop 作废时不算失败，静默退出避免误回退系统 TTS
        if (gen != _generation) return;
        lastError = e.toString();
        debugPrint('Edge TTS 失败，回退系统 TTS：$e');
      }
    }
    await _speakSystem(plain, rate, volume);
  }

  /// 停止播报（MP3 播放器与系统 TTS 都停）。
  ///
  /// 自增世代号，作废所有在途的合成/播放流程。
  Future<void> stopSpeaking() async {
    _generation++;
    try {
      await _audio.stop();
    } catch (_) {}
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
    // 同一次请求必须复用同一个 ConnectionId：URL 与 SSML 里的
    // X-RequestId 都用它，服务端才能把两条日志关联到同一次合成。
    //
    // ⚠️ 必须是 32 位十六进制（16 字节）——用短 id 时服务端不产音频，
    // 只回turn.end，表现为「连接成功但没有声音」。
    final connectionId = edgeConnectionId();
    final timestamp = edgeTimestamp();
    final url = Uri.parse('$_wsBase'
        '?TrustedClientToken=$trustedClientToken'
        '&ConnectionId=$connectionId'
        '&Sec-MS-GEC=${edgeSecMsGec()}'
        '&Sec-MS-GEC-Version=1-$_chromiumFull');

    final headers = {
      'Origin': _origin,
      'User-Agent': _userAgent,
      'Pragma': 'no-cache',
      'Cache-Control': 'no-cache',
    };

    // ⚠️ 不能用 `WebSocket.connect`：它会在 User-Agent 前面拼上
    // `Dart/<版本> (dart:io), `，变成
    //   user-agent: Dart/3.13 (dart:io), Mozilla/5.0 ... Edg/143.0.0.0
    // 微软按 UA 判定客户端，非浏览器 UA 直接返回 403 Forbidden。
    // 实测（同一台机器、同一网络）：
    //   -裸 socket + 纯浏览器 UA        → 101 Switching Protocols
    //   - WebSocket.connect（UA 被污染） → 403
    // 参见 docs/PROJECT.md §5.7。
    //
    // 所以这里自己实现 WebSocket 握手：SecureSocket + 手写 HTTP Upgrade，
    // 从而完全控制请求头。代价是要自己实现帧编解码（见下方 _wsEncodeText）。
    final ws = await _edgeHandshake(url, headers,
        timeout: const Duration(seconds: 15));

    final audio = BytesBuilder(copy: false);
    final done = Completer<void>();
    final handshake = Completer<void>();

    // 音频在【文本帧】里（opcode 0x1），不在二进制帧。
    // 实测服务端格式：
    //   X-RequestId:...\r\nContent-Type:audio/mpeg\r\nX-StreamId:...\r\n
    //   Path:audio\r\n\r\n<MP3 数据>
    // 原实现只解析二进制帧（opcode 0x2），因此即使握手成功也一字节音频都拿不到，
    // 表现为「连接正常但没有声音」。
    //
    // ws 是裸 Socket（自己做的握手），所以要先做 WebSocket 帧解码才知道
    // 每块是文本帧还是二进制帧；握手响应本身也要在这里面消费掉。
    final decoder = _WsFrameDecoder();
    final hsBuf = BytesBuilder(copy: true);
    var upgraded = false;
    final sub = ws.listen(
      (dynamic raw) {
        if (raw is! List<int>) return;
        final bytes = Uint8List.fromList(raw);

        // 第一步：吃掉 HTTP Upgrade 响应
        if (!upgraded) {
          hsBuf.add(bytes);
          final h = Uint8List.fromList(hsBuf.toBytes());
          final end = _indexOfHeaderEnd(h, 0);
          if (end < 0) return;
          final head = latin1.decode(h, allowInvalid: true);
          final statusLine = head.split('\r\n').first;
          if (!statusLine.contains(' 101')) {
            ws.destroy();
            if (!handshake.isCompleted) {
              handshake.completeError(
                  Exception('Edge TTS 握手失败：$statusLine'));
            }
            return;
          }
          upgraded = true;
          if (!handshake.isCompleted) handshake.complete();
          // 响应之后可能紧跟 WebSocket 帧
          final rest = Uint8List.sublistView(h, end);
          if (rest.isEmpty) return;
          _onFrames(decoder, rest, audio, done);
          return;
        }

        _onFrames(decoder, bytes, audio, done);
      },
      onError: (Object e) {
        if (!handshake.isCompleted) {
          handshake.completeError(e);
        } else if (!done.isCompleted) {
          done.completeError(e);
        }
      },
      onDone: () {
        if (!handshake.isCompleted) {
          handshake.completeError(
              Exception('Edge TTS 连接在握手完成前关闭'));
        } else if (!done.isCompleted) {
          done.complete();
        }
      },
      cancelOnError: true,
    );

    // 等握手完成再发业务消息（服务端未Upgrade 前发帧会被忽略）
    try {
      await handshake.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      await sub.cancel();
      ws.destroy();
      rethrow;
    }

    // 握手已升级为裸 socket，所有写入都要自己包成 WebSocket 帧。
    _wsSendText(ws, 'X-Timestamp:$timestamp\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}');

    // Edge 的语速/音量用百分比增量表达
    final ratePct = ((rate - 1.0) * 100).round();
    final volPct = ((volume - 1.0) * 100).round();
    final fullVoice = edgeVoiceName(voice);
    // voice 名来自用户配置，拼入 SSML 属性前必须转义，防止属性值被注入
    // 引号闭合后注入额外属性/元素（P2-14）。rate/volume/pitch 均为代码
    // 计算的数值，无注入面。
    final ssml = "<speak version='1.0' "
        "xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
        "<voice name='${escapeXml(fullVoice)}'>"
        "<prosody pitch='+0Hz' rate='${ratePct >= 0 ? '+' : ''}$ratePct%' "
        "volume='${volPct >= 0 ? '+' : ''}$volPct%'>"
        '${escapeXml(text)}</prosody></voice></speak>';

    // X-Timestamp 必须是 JavaScript 风格且以大写 Z 结尾（微软的 bug 要求，
    // 官方 edge-tts 源码里明确注释了"This is not a mistake"）。
    _wsSendText(ws, 'X-RequestId:$connectionId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${edgeJsTimestamp()}Z\r\n'
        'Path:ssml\r\n\r\n$ssml');

    try {
      await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
      try {
        await ws.close();
      } catch (_) {}
    }
    final out = audio.takeBytes();
    if (out.isEmpty) {
      throw Exception('Edge TTS 未返回音频（握手成功但无 Path:audio 帧）');
    }
    return out;
  }

  /// 用 audioplayers 播放 MP3（底层 ExoPlayer/MediaPlayer）。
  ///
  /// 之前的实现是依次尝试 `/system/bin/stagefright`、`toybox play`、
  /// `ffplay` 三个命令行播放器——在现代 Android 上**全部不可用**：
  ///   - stagefright：Android 10 起已从系统镜像移除；
  ///   - toybox：没有 play 子命令（秒退、非 0 退出码）；
  ///   - ffplay：装在 proot 环境里，app 进程的 PATH 根本看不到。
  /// 结果是 Edge 合成成功也一字节都放不出来，回退系统 TTS 又因
  /// 引擎缺失可能无声，UI 永远停在「播放中…」。
  ///
  /// [gen] 是本次播报的世代号：`play()` 是异步的，用户点「停止」可能
  /// 落在 await 的窗口里；播放期间轮询世代号，被作废立即停下。
  Future<void> _playAudio(String path, int gen) async {
    try {
      await _audio.stop();
    } catch (_) {}
    await _audio.play(DeviceFileSource(path));

    // 自然播完时 onPlayerComplete 触发；被 stopSpeaking 中断时
    // complete 不会触发，靠 150ms 一次的世代号轮询退出。
    final completed = Completer<void>();
    final sub = _audio.onPlayerComplete.listen((_) {
      if (!completed.isCompleted) completed.complete();
    });
    try {
      while (!completed.isCompleted && gen == _generation) {
        await Future.any<void>([
          completed.future,
          Future<void>.delayed(const Duration(milliseconds: 150)),
        ]);
      }
    } finally {
      await sub.cancel();
      try {
        await _audio.stop();
      } catch (_) {}
    }
  }

  Future<void> _speakSystem(String plain, double rate, double volume) async {
    try {
      await _tts.setLanguage('zh-CN');
      // flutter_tts 的 rate 是 0.0~1.0 平台相关量，0.5 约等于正常语速。
      // clamp 在 double 上返回 num，需 toDouble() 才能匹配 setSpeechRate(double)。
      await _tts.setSpeechRate((0.5 * rate).clamp(0.05, 1.0).toDouble());
      await _tts.setVolume(volume.clamp(0.0, 1.0).toDouble());
      await _tts.stop();
      // 超时兜底：设备缺 TTS 引擎 / 语言数据损坏时，完成回调永远不来，
      // speak 的 await 不返回，UI 就永远停在「播放中…」。
      await _tts
          .speak(plain)
          .timeout(const Duration(seconds: 60), onTimeout: () {});
    } catch (e) {
      debugPrint('系统 TTS 播放失败：$e');
      lastError ??= '系统 TTS 不可用：$e';
    }
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

/// 一帧 WebSocket 数据（含 opcode）。
class _WsFrame {
  const _WsFrame(this.opcode, this.payload);
  final int opcode;
  final Uint8List payload;
}

/// 增量式 WebSocket 帧解码器（RFC 6455 服务端侧，无掩码）。
///
/// TCP 是字节流，一次 socket 回调可能包含半帧、多帧或跨帧边界，
/// 所以必须自己缓冲拼帧——`WebSocket` 类帮了这个忙，
/// 但我们为了控制 User-Agent 自己做握手，只能自己实现。
class _WsFrameDecoder {
  final _buf = BytesBuilder(copy: true);

  /// 喂入原始字节，返回本次可完整解析出的帧。
  List<_WsFrame> add(Uint8List chunk) {
    _buf.add(chunk);
    final frames = <_WsFrame>[];
    final data = _buf.toBytes();

    var pos = 0;
    while (true) {
      if (data.length - pos < 2) break;
      final b0 = data[pos];
      final b1 = data[pos + 1];
      final opcode = b0 & 0x0F;
      final masked = (b1 & 0x80) != 0;
      var len = b1 & 0x7F;
      var p = pos + 2;

      if (len == 126) {
        if (data.length < p + 2) break;
        len = (data[p] << 8) | data[p + 1];
        p += 2;
      } else if (len == 127) {
        if (data.length < p + 8) break;
        len = 0;
        for (var i = 0; i < 8; i++) {
          len = (len << 8) | data[p + i];
        }
        p += 8;
      }

      var maskKey = <int>[];
      if (masked) {
        if (data.length < p + 4) break;
        maskKey = data.sublist(p, p + 4);
        p += 4;
      }
      if (data.length < p + len) break;

      var payload = Uint8List.fromList(data.sublist(p, p + len));
      if (masked) {
        for (var i = 0; i < payload.length; i++) {
          payload[i] ^= maskKey[i % 4];
        }
      }
      frames.add(_WsFrame(opcode, payload));
      pos = p + len;
    }

    // 保留未消费的尾巴
    _buf.clear();
    if (pos < data.length) {
      _buf.add(Uint8List.sublistView(data, pos));
    }
    return frames;
  }
}

/// 解析 Edge 的一帧。
///
/// ⚠️ 音频帧是**文本帧**（opcode 0x1），不是二进制帧：
///   X-RequestId:...\r\nContent-Type:audio/mpeg\r\nX-StreamId:...\r\n
///   Path:audio\r\n\r\n<MP3 数据>
/// 服务端偶尔也会发二进制帧（0x8E0=2288 字节的头部长度格式）。
/// 原实现只处理二进制帧，导致握手成功后一字节音频都拿不到。
///
/// 两种格式统一按「头部文本 + \r\n\r\n + 负载」切分：
/// - 文本帧：直接是 ASCII 头
/// - 二进制帧：前 2 字节大端 = 头部长度
EdgeFrame? parseEdgeFrame(Uint8List bytes, {bool isText = false}) {
  var headerStart = 0;
  var payloadStart = -1;

  if (isText) {
    payloadStart = _indexOfHeaderEnd(bytes, 0);
    if (payloadStart < 0) return null;
  } else {
    if (bytes.length < 2) return null;
    final headerLen = (bytes[0] << 8) | bytes[1];
    if (headerLen <= 0 || 2 + headerLen > bytes.length) return null;
    headerStart = 2;
    payloadStart = 2 + headerLen;
  }

  final header = latin1.decode(
    bytes.sublist(headerStart, payloadStart),
    allowInvalid: true,
  );
  return EdgeFrame(
    header: header,
    payload: Uint8List.sublistView(bytes, payloadStart),
  );
}

/// 找到\r\n\r\n 的位置（即头部结束处），返回负载起始下标；找不到返回 -1。
int _indexOfHeaderEnd(Uint8List b, int from) {
  for (var i = from; i + 3 < b.length; i++) {
    if (b[i] == 0x0D &&
        b[i + 1] == 0x0A &&
        b[i + 2] == 0x0D &&
        b[i + 3] == 0x0A) {
      return i + 4;
    }
  }
  return -1;
}

/// 编码一个客户端掩码文本帧（RFC 6455 opcode 0x1）。
Uint8List _wsEncodeText(String text, {int maskKey = 0x2A3B4C5D}) {
  final payload = utf8.encode(text);
  final out = BytesBuilder(copy: false);
  out.addByte(0x81); // FIN=1, opcode=text
  final n = payload.length;
  if (n < 126) {
    out.addByte(0x80 | n);
  } else if (n < 65536) {
    out.addByte(0x80 | 126);
    out.addByte((n >> 8) & 0xFF);
    out.addByte(n & 0xFF);
  } else {
    out.addByte(0x80 | 127);
    for (var i = 7; i >= 0; i--) {
      out.addByte((n >> (i * 8)) & 0xFF);
    }
  }
  out.addByte((maskKey >> 24) & 0xFF);
  out.addByte((maskKey >> 16) & 0xFF);
  out.addByte((maskKey >> 8) & 0xFF);
  out.addByte(maskKey & 0xFF);
  for (var i = 0; i < n; i++) {
    out.addByte(payload[i] ^ ((maskKey >> (24 - (i % 4) * 8)) & 0xFF));
  }
  return out.toBytes();
}

void _wsSendText(Socket sock, String text) {
  sock.add(_wsEncodeText(text));
}

/// 处理一批已解码的 WebSocket 帧：累加音频、检测结束标记。
void _onFrames(
  _WsFrameDecoder decoder,
  Uint8List bytes,
  BytesBuilder audio,
  Completer<void> done,
) {
  for (final frame in decoder.add(bytes)) {
    // 关闭帧（opcode 0x8）必须单独处理，**不能**丢给 parseEdgeFrame：
    // 它的负载是「2 字节状态码 + UTF-8 原因」，没有 `\r\n\r\n` 头，
    // 解析会返回 null 而被静默忽略 —— 然后调用方只能干等超时。
    //
    // 服务端拒绝请求时正是这么做的：先回 Path:turn.start，
    // 紧接着发关闭帧 `code=1007 reason="Unsupported voice ..."` 并断开。
    // 不解析它就只能看到「30 秒后没拿到音频」，完全无从下手排查
    // （本次「Edge 语音没声音」就是栽在这里）。
    if (frame.opcode == 0x8) {
      if (!done.isCompleted) {
        done.completeError(EdgeClosedException(edgeCloseReason(frame.payload)));
      }
      continue;
    }

    final parsed = parseEdgeFrame(frame.payload, isText: frame.opcode == 0x1);
    if (parsed == null) continue;
    if (parsed.isAudio) {
      audio.add(parsed.payload);
    } else if (parsed.isTurnEnd) {
      if (!done.isCompleted) done.complete();
    }
  }
}

/// 从关闭帧负载里取原因：前 2 字节是大端状态码，其余是 UTF-8 文本。
///
/// 公开出来便于单元测试（）—— 这条诊断信息
/// 是定位「音色名被拒」的关键，值得锁住其格式。
String edgeCloseReason(Uint8List payload) {
  if (payload.length < 2) return '服务端关闭连接（无原因）';
  final code = (payload[0] << 8) | payload[1];
  final why =
      utf8.decode(payload.sublist(2), allowMalformed: true).trim();
  return why.isEmpty
      ? '服务端关闭连接（code=$code）'
      : '服务端关闭连接（code=$code）：$why';
}

/// Edge 服务端主动关闭连接。携带它给出的原因，便于定位。
///
/// 最常见的原因就是音色名不被接受（code=1007 Unsupported voice）——
/// 见 [edgeVoiceName]。
class EdgeClosedException implements Exception {
  const EdgeClosedException(this.message);
  final String message;

  @override
  String toString() => 'Edge TTS $message';
}

/// 手工完成 Edge 的 WebSocket 握手，返回**已连接但未订阅**的 socket。
///
/// 不能用 `WebSocket.connect`：Dart 会在User-Agent 前拼上
/// `Dart/<版本> (dart:io), `，微软据此判定为非浏览器客户端并返回 403。
/// 详见 docs/PROJECT.md §5.7。
///
/// ⚠️ 返回后**不要**再监听返回的 socket——调用方必须先建立唯一的
/// `listen()`，否则 `Stream has already been listened to`。
/// 本函数内部只写握手请求、不读响应（响应由调用方的订阅消费）。
Future<Socket> _edgeHandshake(
  Uri url,
  Map<String, String> headers, {
  required Duration timeout,
}) async {
  final host = url.host;
  final port = url.hasPort ? url.port : 443;
  final sock = await SecureSocket.connect(host, port,
      context: SecurityContext(withTrustedRoots: true))
      .timeout(timeout);

  // Sec-WebSocket-Key 必须是 base64 的 16 字节
  final rnd = math.Random.secure();
  final key = base64.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));

  final sb = StringBuffer()
    ..write('GET ${url.path}'
        '${url.hasQuery ? '?${url.query}' : ''} HTTP/1.1\r\n')
    ..write('Host: $host\r\n')
    ..write('Upgrade: websocket\r\n')
    ..write('Connection: Upgrade\r\n')
    ..write('Sec-WebSocket-Key: $key\r\n')
    ..write('Sec-WebSocket-Version: 13\r\n');
  headers.forEach((k, v) => sb.write('$k: $v\r\n'));
  sb.write('\r\n');

  sock.add(utf8.encode(sb.toString()));
  await sock.flush();
  return sock;
}

/// 计算 Sec-MS-GEC 签名。
///
/// 算法（与官方 edge-tts 的 `generate_sec_ms_gec` 逐位一致）：
/// 把当前时间转成 Windows FILETIME **秒**（1601 起算）→ 向下圆整到
/// 5 分钟窗口（300 秒）→ 乘 10^7 换成 100ns 刻度 → 取
/// `SHA256(ticks + TrustedClientToken)` 的大写十六进制。
/// 签名有效期约 5 分钟。
///
/// ⚠️ 顺序不能颠倒：必须「先对秒取整窗口、再乘 10^7」。
/// 之前的实现是先乘 10^7 再对 3×10^9 取模——当秒的余数恰为 299 且
/// 亚秒部分 ≥ 0.1s 时，结果会比官方多整整一个窗口（300 秒），
/// 服务端直接 403。属于低概率但必现于固定时段的签名错位。
String edgeSecMsGec({DateTime? now}) {
  final t = (now ?? DateTime.now()).toUtc();
  // ⚠️ 本函数在 VoiceService 类【外部】，访问其私有静态常量必须带类名前缀，
  // 裸写 _winEpochSeconds 是 undefined_identifier。
  var sec =
      (t.millisecondsSinceEpoch / 1000).floor() + VoiceService._winEpochSeconds;
  sec -= sec % 300;
  final ticks = sec * 10000000; // 64 位 int 容得下（约 7.3e16）
  final raw = '$ticks${VoiceService.trustedClientToken}';
  return sha256.convert(utf8.encode(raw)).toString().toUpperCase();
}

/// Edge 协议里的时间戳：UTC 的 `yyyy-MM-ddTHH:mm:ss.fffZ`。
/// 用于 speech.config 消息。
String edgeTimestamp({DateTime? now}) {
  final t = (now ?? DateTime.now()).toUtc();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${t.year}-${p(t.month)}-${p(t.day)}T'
      '${p(t.hour)}:${p(t.minute)}:${p(t.second)}'
      '.${p(t.millisecond, 3)}Z';
}

/// SSML 消息专用的 JavaScript 风格时间戳。
///
/// ⚠️ 微软的 SSML 接口要求这种格式，且**末尾必须再补一个大写 Z**
/// （官方 edge-tts 源码里标注 "This is not a mistake, Microsoft Edge bug"）。
/// 形如：
///   Sat Oct 03 2026 05:00:10 GMT+0000 (Coordinated Universal Time)Z
/// 之前用 ISO 格式（2026-10-03T05:00:10.000Z）服务端不产音频。
String edgeJsTimestamp({DateTime? now}) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final t = (now ?? DateTime.now()).toUtc();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${weekdays[t.weekday - 1]} ${months[t.month - 1]} '
      '${p(t.day)} ${t.year} '
      '${p(t.hour)}:${p(t.minute)}:${p(t.second)} '
      'GMT+0000 (Coordinated Universal Time)';
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

/// 把音色短名转成 Edge 协议要求的完整音色名。
///
/// ⚠️ 这是「Edge 语音没声音」的真根因，踩过：
///
/// 服务端实际接受两种写法：
///   1. 短名            `zh-CN-XiaoxiaoNeural`
///   2. 完整名          `Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)`
///
/// 而**不接受**「短名直接塞进括号」的混血形式：
///   `Microsoft Server Speech Text to Speech Voice (zh-CN-XiaoxiaoNeural)`
///   → 服务端先回 `Path:turn.start`，紧接着发**关闭帧**
///     `code=1007, reason="Unsupported voice ..."`
///     （实测拿到原始报文才看到，从 UI 上只表现为「播放中…」不动）
///
/// 之前就是这么拼的（locale 与音色名之间用了横线），导致 Edge 语音
/// 完全无输出，但因握手是 101、日志无异常，排查时长期误判成网络或
/// 签名问题。
///
/// 转换规则与官方 edge-tts 的 `TTSConfig.__post_init__` 一致：
///   `zh-CN-XiaoxiaoNeural`         → `(zh-CN, XiaoxiaoNeural)`
///   `zh-CN-liaoning-XiaobeiNeural` → `(zh-CN-liaoning, XiaobeiNeural)`
/// 即分隔符是「逗号 + 空格」而非横线；三级地区（如 liaoning）并入 locale 段。
String edgeVoiceName(String voice) {
  const prefix = 'Microsoft Server Speech Text to Speech Voice';
  // 已经是完整名，原样返回
  if (voice.startsWith(prefix)) return voice;

  final m = RegExp(r'^([a-z]{2,})-([A-Z]{2,})-(.+Neural)$').firstMatch(voice);
  // 不符合规范就把原值送出去，让服务端给出明确错误，而不是我们瞎猜
  if (m == null) return voice;

  var region = m.group(2)!;
  var name = m.group(3)!;
  // 三级地区：`liaoning-XiaobeiNeural` 里的 liaoning 归到 locale 段，
  // 音色名只留 `XiaobeiNeural`。
  final dash = name.indexOf('-');
  if (dash != -1) {
    region = '$region-${name.substring(0, dash)}';
    name = name.substring(dash + 1);
  }
  return '$prefix (${m.group(1)}-$region, $name)';
}

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
