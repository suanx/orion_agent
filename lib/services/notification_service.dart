import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知服务：回答完成、任务结束等场景的提醒。
///
/// 全部为**本地通知**（不经推送服务器），不联网、不需要任何 Key。
class NotificationService {
  NotificationService();

  static const _channelId = 'pocket_agent_agent';
  static const _channelName = 'Agent 通知';
  static const _channelDesc = '回答完成、任务结束等提醒';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;

  /// 是否已就绪（未初始化成功时所有发送调用都会被静默忽略）。
  bool get isReady => _ready;

  /// 初始化。Android 13+ 会触发通知权限请求。
  Future<bool> init({
    void Function(String? payload)? onTap,
  }) async {
    if (_ready) return true;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
        onDidReceiveNotificationResponse: (r) => onTap?.call(r.payload),
      );
      await _createChannel();
      _ready = true;
    } catch (e) {
      debugPrint('通知初始化失败：$e');
      _ready = false;
    }
    return _ready;
  }

  /// Android 8+ 需要显式创建渠道，否则通知不显示。
  Future<void> _createChannel() async {
    if (!Platform.isAndroid) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.defaultImportance,
    ));
  }

  /// 请求通知权限（Android 13+ / iOS）。
  ///
  /// 本应用 targetSdk 为 28（终端环境 exec 需要），在 Android 13+ 上
  /// `requestNotificationsPermission()` 会直接返回 null —— 但 targetSdk < 33
  /// 的系统其实会自动授予 POST_NOTIFICATIONS。因此这里在拿到 null 时
  /// 回退查一次实际状态，避免误判为「未授权」。
  Future<bool> requestPermission() async {
    try {
      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        final ok = await android?.requestNotificationsPermission();
        if (ok != null) return ok;
        return await hasPermission();
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final ok = await ios?.requestPermissions(alert: true, badge: true, sound: true);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 系统层面通知是否已授权。
  Future<bool> hasPermission() async {
    try {
      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        return await android?.areNotificationsEnabled() ?? false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 发一条通知。[body] 为空时只显示标题。
  Future<void> show({
    required int id,
    required String title,
    String? body,
    String? payload,
    bool silent = false,
  }) async {
    if (!await init()) return;
    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: silent
                ? Importance.low
                : Importance.defaultImportance,
            priority: silent ? Priority.low : Priority.defaultPriority,
            playSound: !silent,
            onlyAlertOnce: true,
            styleInformation:
                (body != null && body.isNotEmpty && body.length > 40)
                    ? BigTextStyleInformation(body)
                    : null,
          ),
          iOS: DarwinNotificationDetails(presentSound: !silent),
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('发送通知失败：$e');
    }
  }

  /// 回答完成提醒。
  Future<void> notifyAnswerDone({
    required String sessionTitle,
    required String answer,
    bool preview = true,
    bool silent = false,
  }) async {
    final brief = answer.replaceAll(RegExp(r'\s+'), ' ').trim();
    final body = !preview || brief.isEmpty
        ? null
        : (brief.length > 120 ? '${brief.substring(0, 120)}…' : brief);
    await show(
      id: 1001,
      title: '「$sessionTitle」已生成回答',
      body: body,
      payload: 'chat',
      silent: silent,
    );
  }

  /// 任务/长流程结束提醒。
  Future<void> notifyTaskDone({
    required String title,
    required String detail,
    bool silent = false,
  }) async {
    await show(id: 1002, title: title, body: detail, silent: silent);
  }

  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }
}
