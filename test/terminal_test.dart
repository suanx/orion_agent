import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
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

  // ---- runOn 卡死回归（详见 docs/PROJECT.md §11.12）----

  group('drainProcessStreams', () {
    /// 造一对订阅：内容立即可读，但 close 行为可控。
    /// [closeOut]/[closeErr] 为 false 时模拟 proot 把 fd 继承给 guest 里的
    /// 残留进程 —— Dart 侧 stream 永远收不到 done 事件。
    ({StreamSubscription<String> out, StreamSubscription<String> err})
        makeSubs({required bool closeOut, required bool closeErr}) {
      final o = StreamController<String>();
      final e = StreamController<String>();
      final so = o.stream.listen((_) {});
      final se = e.stream.listen((_) {});
      o.add('__ok__\naarch64\n');
      if (closeOut) o.close();
      if (closeErr) e.close();
      return (out: so, err: se);
    }

    test('两个 stream 正常关闭时立即返回', () async {
      final subs = makeSubs(closeOut: true, closeErr: true);
      final sw = Stopwatch()..start();
      await drainProcessStreams(subs.out, subs.err,
          grace: const Duration(milliseconds: 1500));
      expect(sw.elapsedMilliseconds, lessThan(300),
          reason: '正常路径不该等满 grace');
    });

    test('stream 永不关闭时也在 grace 后放行（回归：曾永久挂起）', () async {
      // proot 会把 stdout/stderr 的 fd 继承给 guest 子进程；只要有进程
      // 持有，asFuture() 永不完成 → 旧实现下检测界面永久转圈。
      final subs = makeSubs(closeOut: true, closeErr: false);
      final sw = Stopwatch()..start();
      await drainProcessStreams(subs.out, subs.err,
          grace: const Duration(milliseconds: 200));
      expect(sw.elapsedMilliseconds, lessThan(1500),
          reason: '必须超时放行，不能无限等待');
    });

    test('放行后两个订阅都被 cancel，不泄漏', () async {
      // 用 controller 的 onCancel 判定：cancel() 被调用时必定触发。
      // ⚠️ 不能用 subscription.asFuture() 判断「是否已关闭」——流没关闭时
      // 它根本不会完成，用它断言会得到错误的结论（实测踩过）。
      final cancelled = <String>[];
      final o = StreamController<String>(onCancel: () => cancelled.add('out'));
      final e = StreamController<String>(onCancel: () => cancelled.add('err'));
      // 两个 controller 都不 close，模拟 proot 把 fd 泄漏给 guest 进程
      await drainProcessStreams(
        o.stream.listen((_) {}),
        e.stream.listen((_) {}),
        grace: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cancelled, containsAll(<String>['out', 'err']),
          reason: '实际被取消的流=$cancelled');
    });
  });

  group('extractRootfsInIsolate', () {
    /// 造一个小 tar.gz（2 个普通文件），返回压缩包路径。
    /// _extractRootfs 只认「解压后目录」，所以这里完整走一遍编码链路：
    /// Archive → TarEncoder → GZipEncoder → 落盘。
    String makeTarGz(Directory tmp) {
      final archive = Archive()
        ..add(ArchiveFile.string('a.txt', 'hello orion'))
        ..add(ArchiveFile.string('usr/bin/tool', '#!/bin/sh\necho ok'));
      final tar = TarEncoder().encode(archive);
      final gz = GZipEncoder().encode(tar)!;
      final path = '${tmp.path}/test-rootfs.tar.gz';
      File(path).writeAsBytesSync(gz);
      return path;
    }

    test('跨 isolate 返回统计并正确落盘（unsendable 回归）', () async {
      // 回归：v0.2.8 真机用 Isolate.run(闭包) 解压，捕获链带出不可发送
      // 对象（UI 日志合帧的 Timer），报「object is unsendable - _Timer」。
      // 现实现跨界只有纯数据 record（Isolate.spawn + 顶层入口函数）。
      final tmp = await Directory.systemTemp.createTemp('orion_extract_test');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final archivePath = makeTarGz(tmp);
      final destDir = '${tmp.path}/rootfs';

      final stats =
          await TerminalService.extractRootfsInIsolate(archivePath, destDir, true);

      expect(stats.createdFiles, 2, reason: '应创建 2 个普通文件');
      expect(stats.skippedUnsafe, 0, reason: '不应有被拒绝条目');
      expect(File('$destDir/a.txt').readAsStringSync(), 'hello orion',
          reason: '文件内容应完整落盘');
      expect(File('$destDir/usr/bin/tool').existsSync(), isTrue,
          reason: '嵌套目录应随解压自动创建');
    });

    test('isolate 内异常转字符串传回并重新抛出', () async {
      final tmp = await Directory.systemTemp.createTemp('orion_extract_test');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      // 不存在的压缩包 → _extractRootfs 内 readAsBytesSync 抛错
      final bad = '${tmp.path}/missing.tar.gz';
      expect(
        () => TerminalService.extractRootfsInIsolate(
            bad, '${tmp.path}/out', true),
        throwsException,
        reason: 'isolate 内异常应转成字符串传回并重新抛出，而不是静默或挂起',
      );
    });
  });
}
