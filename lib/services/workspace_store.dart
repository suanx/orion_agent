import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 工作区目录的统一解析入口。
///
/// 用户可在「存储」设置里选择自定义目录；未选择时回退默认
/// （外部存储的应用专属目录下 `workspace`）。
///
/// 两个消费方必须共用这里，保证路径一致：
///   - 终端环境把它挂载为 guest 内的 `/workspace`
///   - 文件统计/清空工作区按它定位
///
/// 为什么不做内存缓存：设置页随时可能改目录，缓存会让改动
/// 直到重启才生效；`SharedPreferences.getInstance()` 本身有单例
/// 内存缓存，这里的每次解析只有一次 `existsSync` 的开销。
class WorkspaceStore {
  /// 自定义目录在 shared_preferences 中的键。
  static const prefsKey = 'workspace_dir';

  /// 解析最终工作区目录。
  ///
  /// 自定义为空 / 目录无法创建（权限不足、路径非法）时回退默认。
  static Future<String> path() async {
    final prefs = await SharedPreferences.getInstance();
    final custom = prefs.getString(prefsKey)?.trim() ?? '';
    if (custom.isNotEmpty) {
      final dir = Directory(custom);
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        return dir.path;
      } catch (_) {
        // 自定义目录不可用（SD 卡拔出、路径无权限等），回退默认
      }
    }
    return defaultPath();
  }

  /// 默认工作区目录：外部存储的应用专属目录（无需权限，
  /// 系统文件管理器可见）；不可用时退到 appSupport。
  static Future<String> defaultPath() async {
    String base;
    try {
      base = (await getExternalStorageDirectory())?.path ?? '';
    } catch (_) {
      base = '';
    }
    base = base.isEmpty
        ? (await getApplicationSupportDirectory()).path
        : base;
    final ws = Directory('$base/workspace');
    try {
      if (!ws.existsSync()) ws.createSync(recursive: true);
    } catch (_) {}
    return ws.path;
  }
}
