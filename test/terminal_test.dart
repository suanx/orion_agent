import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/services/terminal_service.dart';

void main() {
  test('TerminalResult.versionLine 取首个非空行并截断', () {
    const r = TerminalResult(exitCode: 0, output: '\nNode.js v22.1.0\nmore\n');
    expect(r.versionLine, 'Node.js v22.1.0');
    expect(r.ok, isTrue);

    const long = TerminalResult(exitCode: 0, output: '啊' * 100);
    expect(long.versionLine!.length, 61); // 60 + 省略号
    expect(long.versionLine!.endsWith('…'), isTrue);

    const empty = TerminalResult(exitCode: 0, output: ' \n ');
    expect(empty.versionLine, isNull);
  });
}
