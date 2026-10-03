import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'navigation_service.dart';

/// 本地通知服务：回答完成、任务结束等场景的提醒。
///
/// 全部为**本地通知**（不经推送服务器），不联网、不需要任何 Key。
class NotificationService {
  NotificationService();

  static const _channelId = 'orion_agent_agent';
  static const _channelName = 'Agent 通知';
  static const _channelDesc = '回答完成、任务结束等提醒';
  /// 静音专用渠道。Android O 起通知重要度由渠道决定，实例级 importance
  /// 会被向上钳制到渠道，不能低于渠道——所以静音必须靠独立渠道实现。
  static const _silentChannelId = 'orion_agent_answer_silent';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  /// 进行中的初始化。并发调用共享同一个 Future：
  /// 原实现没有并发保护，main.dart 的 init() 与 show() 里的 init() 可能同时进入，
  /// 输的一方在 _plugin.initialize 处抛异常后走catch，把赢家刚设的
  /// _ready = true 改回 false —— 此后每次 show() 都失败，
  /// 通知【永久失效】且只有重启App 才能恢复。
  Future<bool>? _initializing;
  /// 点击回调单独存字段：原来 onTap 作为参数被 initialize 闭包捕获，
  /// 而 main.dart 先用无参 init() 占位，导致后续传入的 onTap 永远不会被注册，
  /// notifyAnswerDone里精心设置的 payload 成了死代码。
  void Function(String? payload)? _onTap;

  /// 是否已就绪（未初始化成功时所有发送调用都会被静默忽略）。
  bool get isReady => _ready;

  /// 初始化。Android 13+ 会触发通知权限请求。
  Future<bool> init({
    void Function(String? payload)? onTap,
  }) async {
    // 允许后补回调：_ready 短路时也要把新的 onTap 接上。
    if (onTap != null) _onTap = onTap;
    if (_ready) return true;
    final pending = _initializing;
    if (pending != null) return pending;

    final completer = Completer<bool>();
    _initializing = completer.future;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
        // 读字段而非捕获参数，这样后补的回调也能生效
        onDidReceiveNotificationResponse: (r) => _onTap?.call(r.payload),
      );
      await _createChannel();
      _ready = true;
      completer.complete(true);
    } catch (e) {
      debugPrint('通知初始化失败：$e');
      _ready = false;
      completer.complete(false);
    } finally {
      // 允许失败后重试
      _initializing = null;
    }
    return completer.future;
  }

  /// Android 8+ 需要显式创建渠道，否则通知不显示。
  ///
  /// 必须建【两个】渠道：Android O 起通知的重要度由渠道决定，实例级的
  /// importance 会被向上钳制到渠道的重要度，不能低于渠道。若只有 defaultImportance
  /// 的渠道，「静音通知」开关（实例设low）会被系统忽略，仍然响铃震动，
  /// 设置页承诺的"仅横幅提示"完全失效。
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
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _silentChannelId,
      '$_channelName（静音）',
      description: '$_channelDesc（不响铃不震动）',
      importance: Importance.low,
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
      if (Platform.isIOS) {
        // 原来 iOS 直接返回 true：用户可能已拒绝授权，设置页却显示
        // "通知权限已开启"，"授权"按钮也不出现，用户无从知道通知被静音了。
        //
        // 注意字段名是 `isEnabled`（NotificationsEnabledOptions），
        // 没有 isAuthorized —— 写错会编译失败。
        final ios = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        final granted = await ios?.checkPermissions();
        return granted?.isEnabled ?? false;
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
      // 按 silent 路由到不同渠道：Android O 起实例级 importance 会被
      // 钳制到渠道级别，单渠道方案下静音开关等于没做。
      final channelId = silent ? _silentChannelId : _channelId;
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            silent ? '$_channelName（静音）' : _channelName,
            channelDescription: _channelDesc,
            importance: silent
                ? Importance.low
                : Importance.defaultImportance,
            priority: silent ? Priority.low : Priority.defaultPriority,
            playSound: !silent,
            // 原来为 true：同 id 通知已在屏幕上时不重复提醒，
            // 而 notifyAnswerDone 固定用 id 1001，于是"第二条回答以后就不响了"。
            onlyAlertOnce: false,
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
      // 用常量而非字面量：payload 由 NavigationService.handlePayload 解析，
      // 两边必须用同一份契约，否则改了这边那边就匹配不上。
      payload: NavPayload.chat,
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
