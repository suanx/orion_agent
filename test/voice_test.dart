import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/services/voice_service.dart';

void main() {
  test('朗读文本清理：去标题/加粗符号，代码块替换', () {
    final s = stripMarkdownForSpeech('# 标题\n\n这是**重点**。\n\n```dart\nint x = 1;\n```');
    expect(s.contains('#'), isFalse);
    expect(s.contains('**'), isFalse);
    expect(s.contains('int x = 1'), isFalse);
    expect(s.contains('重点'), isTrue);
    expect(s.contains('（代码略）'), isTrue);
  });

  test('朗读文本清理：行内代码保留内容，超长截断', () {
    final s = stripMarkdownForSpeech('运行 `flutter test` 查看结果');
    expect(s.contains('flutter test'), isTrue);
    expect(s.contains('`'), isFalse);

    final long = stripMarkdownForSpeech('啊' * 1000);
    expect(long.length, 400);
  });
}
