import 'package:flutter/services.dart';

/// 应用授权页的权限状态集合。
///
/// 全部来自 MethodChannel `orion_agent/system`（见 ci/MainActivity.kt 的
/// permissionStatus），任何一项检查失败在原生侧就降级为 false，
/// 这里只做承载与核心权限计数。
class PermissionStatus {
  const PermissionStatus({
    this.notification = false,
    this.accessibility = false,
    this.battery = false,
    this.overlay = false,
    this.appsList = false,
    this.allFiles = false,
  });

  final bool notification;
  final bool accessibility;
  final bool battery;
  final bool overlay;
  final bool appsList;
  final bool allFiles;

  /// 核心四项（无障碍 / 后台运行 / 悬浮窗 / 应用列表）已就绪数。
  int get coreReady =>
      [accessibility, battery, overlay, appsList].where((e) => e).length;

  factory PermissionStatus.fromMap(Map<Object?, Object?> map) =>
      PermissionStatus(
        notification: map['notification'] == true,
        accessibility: map['accessibility'] == true,
        battery: map['battery'] == true,
        overlay: map['overlay'] == true,
        appsList: map['appsList'] == true,
        allFiles: map['allFiles'] == true,
      );
}

/// 应用权限：统一的状态查询与系统设置页跳转。
///
/// 状态全部实时查询（不缓存）——用户从系统设置页返回后要立刻看到变化，
/// 由页面在 AppLifecycleState.resumed 时重新拉取。
class PermissionService {
  static const _channel = MethodChannel('orion_agent/system');

  Future<PermissionStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
          'permissionStatus');
      return PermissionStatus.fromMap(raw ?? const {});
    } catch (_) {
      // 平台异常（如桌面上跑）返回全 false，页面仍可打开
      return const PermissionStatus();
    }
  }

  /// 跳转对应权限的系统设置页。kind 见 [openPermission] 的分支。
  Future<void> open(String kind) async {
    try {
      await _channel.invokeMethod('openPermission', {'kind': kind});
    } catch (_) {}
  }
}
