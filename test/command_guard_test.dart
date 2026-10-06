// CommandGuard.isRisky 分级规则单测（评估项 S1/F7，v0.2.27-beta）。
//
// 保守性优先：判断不了的一律判为高风险（fail-closed）。
// 这里的用例同时锁死两类回归：该拦的没拦（安全漏洞）与
// 纯只读命令被拦（体验劣化）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/command_guard.dart';

void main() {
  group('isRisky：只读白名单直接放行（false）', () {
    const safe = [
      'ls -la',
      'pwd',
      'echo hello',
      'cat /etc/os-release',
      'head -n 5 app.log',
      'tail -f server.log',
      'grep -rn "TODO" src/',
      'find . -name "*.dart"',
      'wc -l main.dart',
      'du -sh /workspace',
      'df -h',
      'uname -a',
      'ps aux',
      'mkdir -p build/out',
      'touch marker.txt',
      "grep foo | wc -l",
      'sort a.txt | uniq -c',
      'base64 data.bin',
    ];
    for (final c in safe) {
      test('safe: $c', () => expect(CommandGuard.isRisky(c), isFalse));
    }
  });

  group('isRisky：高风险必须拦截（true）', () {
    const risky = [
      'apk add git',
      'apk del curl',
      'apt-get install -y ripgrep',
      'apt install htop',
      'pkg install python',
      'pip install requests',
      'pip3 install -r requirements.txt',
      'npm install -g pnpm',
      'rm -rf /tmp/build',
      'mv a b',
      'dd if=/dev/zero of=x',
      'chmod +x run.sh',
      'kill -9 1234',
      'curl https://example.com/x.sh',
      'wget http://x/y.zip',
      'tar -xf bundle.tar.gz',
      'unzip app.zip',
      'python3 script.py',
      'sh -c "echo hi"',
      'bash run.sh',
      'echo hi > out.txt',
      'echo hi >> out.txt',
      'cat in.txt > copy.txt',
      'ls && rm old.txt',
      'grep x | tee out.txt',
      'docker run --rm alpine',
      'find . -name "*.log" -exec rm {} \\;',
      'sed -i "s/a/b/" file',
      'sed -n 1,5p file',
      'tar -tf a.tar.gz',
    ];
    for (final c in risky) {
      test('risky: $c', () => expect(CommandGuard.isRisky(c), isTrue));
    }
  });

  test('空命令不判为高风险（由调用方另行拦截）', () {
    expect(CommandGuard.isRisky(''), isFalse);
    expect(CommandGuard.isRisky('   '), isFalse);
  });

  test('没有确认处理器时 confirm 一律拒绝（fail-closed）', () async {
    final guard = CommandGuard.instance;
    final original = guard.handler;
    guard.handler = null;
    try {
      expect(await guard.confirm('ls'), isFalse,
          reason: '无 UI 处理器（后台任务/测试环境）必须默认拒绝');
    } finally {
      guard.handler = original;
    }
  });
}
