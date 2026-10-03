import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/terminal_service.dart';

void main() {
  test('TerminalResult.versionLine 取首个非空行并截断', () {
    const r = TerminalResult(exitCode: 0, output: '\nNode.js v22.1.0\nmore\n');
    expect(r.versionLine, 'Node.js v22.1.0');
    expect(r.ok, isTrue);

    final long = TerminalResult(exitCode: 0, output: '啊' * 100);
    expect(long.versionLine!.length, 61); // 60 + 省略号
    expect(long.versionLine!.endsWith('…'), isTrue);

    const empty = TerminalResult(exitCode: 0, output: ' \n ');
    expect(empty.versionLine, isNull);
  });

  test('一键安装脚本包含全部需要的组件', () {
    final alpine = TerminalService.installScriptFor(TerminalDistro.alpine);
    expect(alpine, startsWith('apk add --no-cache'));
    for (final pkg in ['nodejs', 'npm', 'git', 'python3', 'uv', 'openssh', 'sshpass']) {
      expect(alpine, contains(pkg), reason: 'Alpine 缺少 $pkg');
    }
    expect(alpine, contains('opencode-ai'));
    expect(alpine, contains('npmmirror')); // npm 走国内镜像

    final debian = TerminalService.installScriptFor(TerminalDistro.debian);
    expect(debian, startsWith('apt-get update'));
    for (final pkg in ['nodejs', 'git', 'python3-pip', 'openssh-server', 'sshpass']) {
      expect(debian, contains(pkg), reason: 'Debian 缺少 $pkg');
    }
    expect(debian, contains('pip3 install --break-system-packages uv'));
    expect(debian, contains('opencode-ai'));
  });

  test('发行版定义完整', () {
    expect(TerminalService.specs, hasLength(2));
    expect(
        TerminalService.specs[TerminalDistro.debian]!.downloadUrl,
        contains('releases/download/terminal-env'));
    expect(TerminalService.specs[TerminalDistro.alpine]!.isGzip, isTrue);
    expect(TerminalService.specs[TerminalDistro.debian]!.isGzip, isFalse);
  });

  test('TerminalTask JSON 往返与坏输入容错', () {
    const task = TerminalTask(
      name: 'web',
      command: 'python3 /workspace/app.py',
      enabled: false,
      distro: TerminalDistro.debian,
    );
    final restored =
        TerminalTask.decodeList(TerminalTask.encodeList([task])).single;
    expect(restored.name, 'web');
    expect(restored.command, contains('app.py'));
    expect(restored.enabled, isFalse);
    expect(restored.distro, TerminalDistro.debian);

    expect(TerminalTask.decodeList(null), isEmpty);
    expect(TerminalTask.decodeList('not json'), isEmpty);
    expect(TerminalTask.decodeList('[{"name":"a"}]'), hasLength(1));
  });
}
