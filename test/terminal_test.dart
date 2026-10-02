import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/services/terminal_service.dart';

void main() {
  test('TerminalResult.versionLine 取首个非空行并截断', () {
    final r = const TerminalResult(exitCode: 0, output: '\nNode.js v22.1.0\nmore\n');
    expect(r.versionLine, 'Node.js v22.1.0');
    expect(r.ok, isTrue);

    final long = TerminalResult(exitCode: 0, output: '啊' * 100);
    expect(long.versionLine!.length, 61); // 60 + 省略号
    expect(long.versionLine!.endsWith('…'), isTrue);

    const empty = TerminalResult(exitCode: 0, output: ' \n ');
    expect(empty.versionLine, isNull);
  });

  test('双发行版的一键安装命令', () {
    expect(TerminalService.alpineInstallCommand(['nodejs', 'git']),
        'apk add --no-cache nodejs git');
    expect(
        TerminalService.debianInstallCommand(['nodejs', 'git']),
        'apt-get update -qq && '
        'apt-get install -y --no-install-recommends nodejs git');
    expect(TerminalService.installCommandFor(TerminalDistro.alpine, ['vim']),
        'apk add --no-cache vim');
    expect(TerminalService.installCommandFor(TerminalDistro.debian, ['vim']),
        contains('apt-get install'));
  });

  test('发行版定义完整', () {
    expect(TerminalService.specs, hasLength(2));
    expect(
        TerminalService.specs[TerminalDistro.debian]!.downloadUrl,
        contains('releases/download/terminal-env'));
    expect(TerminalService.specs[TerminalDistro.alpine]!.isGzip, isTrue);
    expect(TerminalService.specs[TerminalDistro.debian]!.isGzip, isFalse);
  });
}
