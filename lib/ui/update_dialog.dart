import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/providers.dart';
import '../services/update_service.dart';
import '../theme.dart';
import 'glass.dart';

/// 应用内更新下载弹窗（参考截图样式，2026-10-05）。
///
/// 居中弹窗内完成整个更新流程：更新日志 → 下载进度条（含已下载/总大小
/// 与实时速度）→ 自动拉起安装器。下载中点「稍后再说」会取消下载；
/// 需要「安装未知应用」授权时打开系统授权页，回来后点「重试安装」续接
/// （APK 已落盘，不会重新下载）。
class UpdateDownloadDialog extends ConsumerStatefulWidget {
  const UpdateDownloadDialog({super.key, required this.info});

  final UpdateInfo info;

  /// 入口：统一从这里弹出（启动自动检查 / 关于页）。
  static Future<void> show(BuildContext context, UpdateInfo info) {
    return showGlassDialog<void>(
      context: context,
      barrierDismissible: false, // 下载中误触外部不关闭，走「稍后再说」
      builder: (_) => UpdateDownloadDialog(info: info),
    );
  }

  @override
  ConsumerState<UpdateDownloadDialog> createState() =>
      _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends ConsumerState<UpdateDownloadDialog> {
  final _cancel = CancelToken();

  /// downloading → authorizing → installing → done / failed
  String _phase = 'downloading';
  int _received = 0;
  int _total = 0;
  double _speed = 0; // bytes/s（0.3s 窗口滑动平均）
  int? _lastMs;
  int _lastBytes = 0;
  String? _apkPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 弹窗首帧后自动开始下载（截图交互：弹出即「下载中…」）
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    if (_phase == 'downloading') _cancel.cancel();
    super.dispose();
  }

  String get _apkUrl => widget.info.apkUrl ?? '';

  Future<void> _start() async {
    if (_apkUrl.isEmpty) {
      setState(() {
        _phase = 'failed';
        _error = '该版本没有直接的 APK 下载地址，请到 Releases 页下载';
      });
      return;
    }
    setState(() => _phase = 'downloading');
    try {
      final tmp = await getTemporaryDirectory();
      final savePath = '${tmp.path}/orion_agent_update.apk';
      await Dio().download(_apkUrl, savePath,
          cancelToken: _cancel, onReceiveProgress: _onProgress);
      if (!mounted) return;
      setState(() {
        _apkPath = savePath;
        _phase = 'installing';
      });
      await _install();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel || !mounted) return;
      setState(() {
        _phase = 'failed';
        _error = '$e';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = 'failed';
        _error = '$e';
      });
    }
  }

  void _onProgress(int received, int total) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastMs == null) {
      _lastMs = now;
      _lastBytes = received;
    } else {
      final dt = (now - _lastMs!) / 1000;
      if (dt >= 0.3) {
        _speed = (received - _lastBytes) / dt;
        _lastMs = now;
        _lastBytes = received;
      }
    }
    if (!mounted) return;
    setState(() {
      _received = received;
      _total = total;
    });
  }

  /// 拉起 APK 安装器；未授权「安装未知应用」时先跳授权页。
  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) return;
    try {
      final perms = ref.read(permissionServiceProvider);
      if (!await perms.canInstallPackages()) {
        if (!mounted) return;
        setState(() => _phase = 'authorizing');
        await perms.open('install');
        return;
      }
      if (!mounted) return;
      setState(() => _phase = 'launching');
      final r = await OpenFilex.open(path);
      if (!mounted) return;
      if (r.type != ResultType.done) throw Exception(r.message);
      setState(() => _phase = 'done');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = 'failed';
        _error = '$e';
      });
    }
  }

  String _mb(int bytes) {
    final v = bytes / (1024 * 1024);
    return v < 10 ? v.toStringAsFixed(1) : v.round().toString();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      title: Text('发现新版本 v${info.version}'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (info.changelog != null && info.changelog!.isNotEmpty)
                Text(
                  info.changelog!,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.55,
                      color: onSurface(context, 0.7)),
                )
              else
                Text('建议更新以获得最新功能与修复。',
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: onSurface(context, 0.55))),
              if (_phase == 'downloading') ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _total > 0
                      ? '下载中 ${_mb(_received)}/${_mb(_total)} MB'
                          ' · ${(_speed / (1024 * 1024)).toStringAsFixed(1)} MB/s'
                      : '下载中 ${_mb(_received)} MB · '
                          '${(_speed / (1024 * 1024)).toStringAsFixed(1)} MB/s',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.5)),
                ),
              ],
              if (_phase == 'authorizing') ...[
                const SizedBox(height: 16),
                Text('APK 已下载完成。需要允许「安装未知应用」：'
                    '已打开系统授权页，开启后回来点「重试安装」。',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: onSurface(context, 0.6))),
              ],
              if (_phase == 'launching') ...[
                const SizedBox(height: 16),
                Text('正在启动安装器…',
                    style: TextStyle(
                        fontSize: 12.5, color: onSurface(context, 0.6))),
              ],
              if (_phase == 'done') ...[
                const SizedBox(height: 16),
                Text('已启动安装器，按系统提示完成升级。',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.primary)),
              ],
              if (_phase == 'failed' && _error != null) ...[
                const SizedBox(height: 16),
                Text('失败：${_error!.split('\n').first}',
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFFD93025))),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_phase == 'downloading') _cancel.cancel();
            Navigator.pop(context);
          },
          child: const Text('稍后再说'),
        ),
        if (_phase == 'downloading')
          const TextButton(
            onPressed: null,
            child: Text('下载中…'),
          )
        else if (_phase == 'authorizing')
          FilledButton(onPressed: _install, child: const Text('重试安装'))
        else if (_phase == 'failed')
          FilledButton(onPressed: _start, child: const Text('重试'))
        else if (_phase == 'done')
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成')),
      ],
    );
  }
}
