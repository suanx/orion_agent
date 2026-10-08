import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 诊断日志：内存环形缓冲 + 落盘持久化 + 全局 debugPrint 桥接。
///
/// 用户在「关于 → 日志」页查看/筛选/导出，回答两类问题：
/// 1. **哪项功能启动失败了** —— main.dart 的启动阶段与后台任务全部打点，
///    失败走 [e]，成功走 [i]；
/// 2. **刚才发生了什么** —— 全 App 的 `debugPrint` 被 [installDebugPrintBridge]
///    接管，39 处既有调用点（网络失败、DB 降级、MCP 连不上……）自动进日志，
///    不需要逐处改代码。
///
/// 三层存储，各司其职：
/// - **内存**（[_entries]，2000 条环形）：当前会话，打开日志页秒出；
/// - **磁盘**（`documents/logs/orion_<时间戳>.log`）：跨重启保留最近 5 次
///   启动，崩溃后仍能翻到崩溃前最后几条 —— 这正是环形内存做不到的；
/// - **UI**（[revision]）：变更即通知，日志页自动刷新，不用手点。
///
/// 约定：不要把 API Key / 消息正文打进日志，只记录事件与错误摘要。
class AppLog {
  AppLog._();

  /// 内存环形上限。落盘不受此限（另有 1MB 单文件上限）。
  static const _maxEntries = 2000;

  /// 单次启动的日志文件上限，超过就停写 —— 无上限的日志文件会把
  /// 手机存储吃满，而 1MB 已足够覆盖一整轮排障。
  static const _maxFileBytes = 1024 * 1024;

  /// 磁盘保留的启动次数（含本次）。
  static const _maxSessions = 5;

  /// 落盘批处理间隔：高频路径（流式输出、轮询）逐条 writeAsString 会把
  /// I/O 打满，攒 400ms 再写。错误例外，见 [e]。
  static const _flushDelay = Duration(milliseconds: 400);

  static const List<String> _levels = ['D', 'I', 'W', 'E'];

  static final List<String> _entries = <String>[];

  /// 版本号：每次写入自增。日志页 [ValueListenableBuilder] 监听它，
  /// 实现"开着页面看直播"，不需要用户手动刷新。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String? _sessionFile;
  static String? _prevFile;
  static bool _initialized = false;
  static bool _truncated = false;
  static final List<String> _pending = <String>[];
  static Timer? _flushTimer;
  static DebugPrintCallback? _originalDebugPrint;

  /// 本次启动的日志文件路径（未初始化或建目录失败时为 null）。
  static String? get sessionFile => _sessionFile;

  /// 上一次启动的日志文件路径（App 首次安装时为 null）。
  static String? get previousFile => _prevFile;

  static Iterable<String> get entries => List.unmodifiable(_entries);

  // ---------------- 初始化与落盘 ----------------

  /// 建日志目录并确定本次启动的文件（**必须在第一次写日志之前调用**，
  /// 否则本会话只留在内存里、崩溃后拿不到）。
  ///
  /// 放在 documents 而非 temp：临时目录随时可能被系统清理，
  /// 而"崩溃后还能翻到上一次的日志"正是持久化的意义。
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/logs');
      if (!await dir.exists()) await dir.create(recursive: true);

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      // 最后一个历史文件 = 上次启动的日志（给日志页"上次启动"标签用）
      _prevFile = files.isEmpty ? null : files.last.path;

      // 只留最近 N 次，更早的直接删——留着没人看还占地方
      final overflow = files.length - (_maxSessions - 1);
      if (overflow > 0) {
        for (final f in files.take(overflow)) {
          try {
            f.deleteSync();
          } catch (_) {
            // 删不掉就算了，不影响本次写入
          }
        }
      }

      final ts = DateTime.now()
          .toString()
          .replaceAll(RegExp(r'[^0-9]'), '')
          .substring(0, 17); // yyyyMMddHHmmssSSS
      final f = File('${dir.path}/orion_$ts.log');
      await f.create(recursive: true);
      _sessionFile = f.path;
    } catch (_) {
      // 拿不到文档目录（极端权限/平台差异）→ 降级为纯内存日志，功能不废
      _sessionFile = null;
    }
  }

  static void _add(String level, String msg) {
    if (msg.isEmpty) return;
    final ts = DateTime.now().toIso8601String().substring(11, 23); // HH:mm:ss.SSS
    final line = '[$ts][$level] $msg';
    _entries.add(line);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    revision.value++;
    _pending.add(line);
    // 防爆：组件每帧都抛错时，400ms 内可能攒出上万行。
    // 内存里的 [_entries] 有环形上限，落盘缓冲也得有一个。
    if (_pending.length > 500) {
      _pending.removeRange(0, _pending.length - 500);
    }
    _scheduleFlush();
    // 刷新通知按级别区别对待：错误要立刻让日志页亮红，普通日志
    // （流式输出可能一秒几十条）攒 150ms 再通知一次，避免每条都
    // 触发整列表重建把 UI 打卡。
    if (level == 'E' || level == 'W') {
      _scheduleNotify(immediate: true);
    } else {
      _scheduleNotify();
    }
  }

  static Timer? _notifyTimer;

  static void _scheduleNotify({bool immediate = false}) {
    if (immediate) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      revision.value++;
      return;
    }
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 150), () {
      _notifyTimer = null;
      revision.value++;
    });
  }

  static void _scheduleFlush() {
    if (_sessionFile == null || _flushTimer != null) return;
    _flushTimer = Timer(_flushDelay, () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  /// 立即落盘。错误日志走这里 —— 崩溃前的最后一条错误如果还躺在内存里，
  /// 等 400ms 就永远等不到了。
  static Future<void> _flush({bool force = false}) async {
    if (_sessionFile == null) return;
    if (!force && _flushTimer != null) return; // 有排定的批次，交它写
    final lines = List<String>.of(_pending);
    _pending.clear();
    if (lines.isEmpty) return;
    try {
      final f = File(_sessionFile!);
      if (await f.exists() && await f.length() > _maxFileBytes) {
        if (!_truncated) {
          _truncated = true;
          await f.writeAsString(
              '…日志已达 ${_maxFileBytes ~/ 1024}KB 上限，本次启动后续不再写入…\n',
              mode: FileMode.append);
        }
        return;
      }
      await f.writeAsString('${lines.join('\n')}\n', mode: FileMode.append);
    } catch (_) {
      // 落盘失败不能影响内存日志（磁盘满/权限变化都可能）
    }
  }

  // ---------------- 写入接口 ----------------

  /// 调试信息：`debugPrint` 桥接、后台任务完成打点等。
  static void d(String msg) => _add('D', msg);

  static void i(String msg) => _add('I', msg);

  /// 警告：功能没崩但没按预期工作（网络失败降级、配置缺失…）。
  /// 用 W 而非 E 是为了别把日志刷成一片红，让真正的错误显不出来。
  static void w(String msg, [Object? error]) =>
      _add('W', error == null ? msg : '$msg :: $error');

  /// 错误：**同步强制落盘**，避免崩溃把这条丢在内存里。
  static void e(String msg, [Object? error]) {
    _add('E', error == null ? msg : '$msg :: $error');
    unawaited(_flush(force: true));
  }

  /// 立刻把待写缓冲刷进磁盘。启动序列打完点时调一次，
  /// 让"App 在启动阶段就崩了"的情形也能留下完整启动日志。
  static Future<void> flushNow() => _flush(force: true);

  /// 接管全局 `debugPrint`。
  ///
  /// 全 App 已有 39 处 `debugPrint`，其中绝大多数是"某某失败了"这类
  /// 排障信息 —— 逐处改成 AppLog 既费事又容易漏（新增代码还会继续用
  /// debugPrint）。在这里统一接管：先进日志缓冲，再转发原实现，
  /// 控制台行为完全不变。
  ///
  /// 幂等：重复调用只装一次，避免套娃导致日志翻倍。
  static void installDebugPrintBridge() {
    if (_originalDebugPrint != null) return;
    _originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      final m = message ?? '';
      if (m.isNotEmpty) _add('D', m);
      _originalDebugPrint?.call(message, wrapWidth: wrapWidth);
    };
  }

  // ---------------- 读取 ----------------

  /// 上一次启动的日志（磁盘直读，供日志页"上次启动"标签）。
  static Future<List<String>> previousSessionEntries() async {
    final p = _prevFile;
    if (p == null) return const <String>[];
    try {
      final f = File(p);
      if (!await f.exists()) return const <String>[];
      return await f.readAsLines();
    } catch (_) {
      return const <String>[];
    }
  }

  /// 上次启动日志的可读文件名（`orion_20261009042332123.log` → 用于标题）。
  static String? get previousSessionLabel {
    final p = _prevFile;
    if (p == null) return null;
    final name = p.split(Platform.pathSeparator).last;
    return name.replaceFirst('orion_', '').replaceAll('.log', '');
  }

  /// 某一批日志里的各级别条数（日志页底部统计）。
  static Map<String, int> countLevels(Iterable<String> lines) {
    final out = <String, int>{for (final l in _levels) l: 0};
    for (final line in lines) {
      final i = line.indexOf(']');
      // 形如 [04:23:32.123][E] ...
      if (i < 2 || line.length <= i + 3) continue;
      final level = line.substring(i + 2, i + 3);
      if (out.containsKey(level)) out[level] = out[level]! + 1;
    }
    return out;
  }

  // ---------------- 导出 ----------------

  /// 导出为文本文件（temp 目录），返回文件路径；失败返回 null。
  static Future<String?> exportToFile([Iterable<String>? lines]) async {
    try {
      final tmp = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .substring(0, 15);
      final f = File('${tmp.path}/orion_log_$ts.txt');
      final body = (lines ?? _entries).toList();
      await f.writeAsString(body.isEmpty ? '（无日志）' : body.join('\n'),
          flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// 全部日志拼成一段文本（复制到剪贴板用）。
  static String asText([Iterable<String>? lines]) {
    final body = (lines ?? _entries).toList();
    return body.isEmpty ? '（无日志）' : body.join('\n');
  }
}
