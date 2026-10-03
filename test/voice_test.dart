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
}
