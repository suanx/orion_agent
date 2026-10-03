import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/voice_service.dart';

void main() {
  test('朗读文本清理：去标题/加粗符号，代码块替换', () {
    final s = stripMarkdownForSpeech('# 标题\n\n这是**重点**。\n\n```dart\nint x = 1;\n```');
    // 断言消息里带上真实结果，失败时 CI annotation 会直接显示 s 的原文，
    // 无需再依赖 print 或 job log。
    expect(s.contains('#'), isFalse, reason: '仍含#，s=$s');
    expect(s.contains('**'), isFalse, reason: '仍含**，s=$s');
    expect(s.contains('int x = 1'), isFalse, reason: '仍含代码体，s=$s');
    expect(s.contains('重点'), isTrue, reason: '丢失重点，s=$s');
    expect(s.contains('（代码略）'), isTrue, reason: '未替换代码块，s=$s');
  });

  test('朗读文本清理：行内代码保留内容，超长截断', () {
    final s = stripMarkdownForSpeech('运行 `flutter test` 查看结果');
    expect(s.contains('flutter test'), isTrue);
    expect(s.contains('`'), isFalse);

    final long = stripMarkdownForSpeech('啊' * 1000);
    expect(long.length, 400);
  });

  // ---- Edge TTS 协议回归（详见 docs/PROJECT.md §11.9）----

  group('Edge TTS 协议', () {
    test('SSML 时间戳必须是 JS 风格且以大写 Z 结尾', () {
      // now 是命名参数（{DateTime? now}），不是位置参数
      final ts = edgeJsTimestamp(now: DateTime.utc(2026, 10, 3, 5, 0, 10));
      // 周六 2026-10-03
      expect(ts, startsWith('Sat Oct 03 2026 05:00:10 GMT+0000'));
      expect(ts, endsWith('(Coordinated Universal Time)'),
          reason: '微软要求这个 JS 风格后缀，实际=$ts');
      // 旧实现用 ISO 格式（2026-10-03T05:00:10.000Z），服务端不产音频。
      // JS 风格里唯一的大写 T 在 Coordinated Universal Time 里，
      // 所以不能断言「不含 T」，要断言不含 ISO 的日期分隔符。
      expect(ts, isNot(matches(RegExp(r'^\d{4}-\d{2}-\d{2}T'))));
    });

    test('ConnectionId 必须是 32 位十六进制', () {
      final id = edgeConnectionId();
      expect(id.length, 32, reason: '实际=$id');
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id), isTrue,
          reason: '实际=$id');
    });

    test('parseEdgeFrame 能解析文本帧里的音频（原实现只认二进制帧）', () {
      // 服务端实际格式：头部 ASCII + \r\n\r\n + MP3 数据
      const header = 'X-RequestId:abc\r\nContent-Type:audio/mpeg\r\n'
          'X-StreamId:xyz\r\nPath:audio\r\n\r\n';
      final mp3 = <int>[0xFF, 0xFB, 0x90, 0x64];
      final raw = <int>[...latin1.encode(header), ...mp3];
      final f = parseEdgeFrame(Uint8List.fromList(raw), isText: true);
      expect(f, isNotNull);
      expect(f!.isAudio, isTrue, reason: '头=${f.header}');
      expect(f.payload, mp3);
    });

    test('parseEdgeFrame 仍支持二进制帧（前 2 字节为头长度）', () {
      const header = 'Path:turn.end';
      final raw = <int>[
        (header.length >> 8) & 0xFF, header.length & 0xFF,
        ...latin1.encode(header),
      ];
      final f = parseEdgeFrame(Uint8List.fromList(raw));
      expect(f, isNotNull);
      expect(f!.isTurnEnd, isTrue, reason: '头=${f.header}');
    });

    test('parseEdgeFrame 对残缺数据返回 null 而不是抛异常', () {
      expect(parseEdgeFrame(Uint8List.fromList([0x00])), isNull);
      // 头长度声称 100 字节但实际不够
      expect(parseEdgeFrame(Uint8List.fromList([0x00, 0x64, 0x41])), isNull);
    });
  });

  // ---- 音色名转换（详见 docs/PROJECT.md §11.13）----
  //
  // 这是一次「Edge 语音完全没声音」的真根因：音色名拼错，
  // 服务端回 1007 Unsupported voice 并立即关闭连接。

  group('edgeVoiceName', () {
    test('locale 与音色名之间是「逗号+空格」，不是横线', () {
      final n = edgeVoiceName('zh-CN-XiaoxiaoNeural');
      expect(n, 'Microsoft Server Speech Text to Speech Voice '
          '(zh-CN, XiaoxiaoNeural)');

      // 回归断言：绝不能拼成下面这种混血形式。
      // 服务端对它的响应是 1007 Unsupported voice + 立即关闭连接，
      // 表现为握手 101、日志无异常，只是永远拿不到音频。
      expect(n, isNot(contains('(zh-CN-XiaoxiaoNeural)')),
          reason: '错误形式会让服务端拒绝该音色');
      expect(n, contains(', '), reason: '分隔符必须是逗号+空格');
    });

    test('三段式 locale：把第三段地区并进 locale', () {
      // 晓北（东北）：zh-CN-liaoning-XiaobeiNeural
      expect(edgeVoiceName('zh-CN-liaoning-XiaobeiNeural'),
          'Microsoft Server Speech Text to Speech Voice '
          '(zh-CN-liaoning, XiaobeiNeural)');
      // 晓妮（陕西）
      expect(edgeVoiceName('zh-CN-shaanxi-XiaoniNeural'),
          'Microsoft Server Speech Text to Speech Voice '
          '(zh-CN-shaanxi, XiaoniNeural)');
    });

    test('已是完整音色名时原样返回（幂等）', () {
      const full = 'Microsoft Server Speech Text to Speech Voice '
          '(zh-CN, XiaoxiaoNeural)';
      expect(edgeVoiceName(full), full);
      // 连续调用两次结果相同
      expect(edgeVoiceName(edgeVoiceName('zh-CN-XiaoxiaoNeural')), full);
    });

    test('不符合规范的音色名原样送出，交给服务端报错', () {
      // 我们不做猜测性改写：送原值，让服务端回明确错误，
      // 好过拼出一个服务端看不懂的名字而没有线索。
      expect(edgeVoiceName('NotAVoice'), 'NotAVoice');
      expect(edgeVoiceName(''), '');
    });

    test('项目内置的 7 个音色全部可正确转换', () {
      // 与 voice_service.dart 里的 kEdgeVoices 保持一致
      const ids = [
        'zh-CN-XiaoxiaoNeural',
        'zh-CN-XiaoyiNeural',
        'zh-CN-YunxiNeural',
        'zh-CN-YunyangNeural',
        'zh-CN-YunjianNeural',
        'zh-CN-liaoning-XiaobeiNeural',
        'zh-CN-shaanxi-XiaoniNeural',
      ];
      for (final id in ids) {
        final n = edgeVoiceName(id);
        expect(n, startsWith('Microsoft Server Speech Text to Speech Voice ('),
            reason: '$id 转换结果=$n');
        expect(n, endsWith(')'), reason: '$id 转换结果=$n');
        // 完整名的格式约束（与服务端校验正则一致）
        expect(RegExp(r'^\(.+,.+\)$').hasMatch(n.substring(n.indexOf('('))),
            isTrue,
            reason: '$id 转换结果=$n 不满足服务端要求的 (locale, name) 形式');
        // 关键：locale 段不能含音色名的横线残留
        expect(n, isNot(contains('Neural,')),
            reason: '$id 转换结果=$n 把音色名留在了 locale 段');
      }
    });
  });

  // ---- 关闭帧原因解析（详见 docs/PROJECT.md §11.13）----
  //
  // 服务端拒绝请求时会先回 Path:turn.start，再发关闭帧
  // `code=1007 reason="Unsupported voice ..."` 并断开。
  // 关闭帧负载**没有** `\r\n\r\n` 头，parseEdgeFrame 会返回 null，
  // 旧实现直接忽略它 —— 于是调用方只能干等 30 秒超时，
  // 拿到「未返回音频」这种毫无线索的信息。

  group('edgeCloseReason', () {
    /// 构造关闭帧负载：2 字节大端状态码 + UTF-8 原因
    Uint8List closePayload(int code, String reason) {
      final r = utf8.encode(reason);
      return Uint8List.fromList(
          [(code >> 8) & 0xFF, code & 0xFF, ...r]);
    }

    test('解析出状态码与原因（音色被拒的真实报文）', () {
      // 实测服务端返回的原文
      final payload = closePayload(
          1007, 'Unsupported voice Microsoft Server Speech Text to '
          'Speech Voice (zh-CN-XiaoxiaoNeural).');
      final msg = edgeCloseReason(payload);
      expect(msg, contains('1007'), reason: '实际=$msg');
      expect(msg, contains('Unsupported voice'), reason: '实际=$msg');
      // 原因文本必须原样透出，这是排查的唯一线索
      expect(msg, contains('zh-CN-XiaoxiaoNeural'), reason: '实际=$msg');
    });

    test('只有状态码、没有原因', () {
      final msg = edgeCloseReason(Uint8List.fromList([0x03, 0xE8]));
      expect(msg, contains('1000'), reason: '实际=$msg');
    });

    test('负载过短时给出兜底文案而不是崩溃', () {
      expect(edgeCloseReason(Uint8List(0)), contains('无原因'));
      expect(edgeCloseReason(Uint8List.fromList([0x03])), contains('无原因'));
    });

    test('状态码按大端解析', () {
      // 0x03EF = 1007
      final msg = edgeCloseReason(Uint8List.fromList([0x03, 0xEF]));
      expect(msg, contains('1007'), reason: '实际=$msg');
    });
  });
}
