import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_config.dart';

/// 一条云端弹窗公告。
class CloudAnnouncement {
  const CloudAnnouncement({
    required this.id,
    required this.title,
    required this.content,
    this.updatedAt = 0,
  });

  final String id;
  final String title;
  final String content;

  /// 服务端 updatedAt（毫秒）。与已读记录一起判断「公告被改过要重弹」。
  final int updatedAt;

  factory CloudAnnouncement.fromJson(Map<String, dynamic> json) =>
      CloudAnnouncement(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  /// 已读标记：`id@updatedAt`。
  ///
  /// 带上 updatedAt 是为了让管理员**改了公告之后能重新弹一次** ——
  /// 只按 id 记录的话，改了内容用户也永远看不到。
  String get seenKey => '$id@$updatedAt';

  @override
  String toString() => 'CloudAnnouncement($id, $title)';
}

/// 云端弹窗公告拉取。
///
/// 后端端点 `GET /api/announcement?platform=&version=` 是**公开**的
/// （无需登录）：公告要在用户还没登录时也能看到。
///
/// 与其他云功能的区别：这里不做「登录才拉取」的短路，也不在网络失败时
/// 抛错 —— 公告属于 best-effort 的附加信息，拉不到就静默跳过，绝不能
/// 影响主流程。
class AnnouncementService {
  AnnouncementService(this._prefs, {Dio? dio})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 8)));

  static const String _seenPrefix = 'announcement.seen.';
  static const String _snoozedKey = 'announcement.snoozedUntilMs';

  final SharedPreferences _prefs;
  final Dio _dio;

  /// 拉取当前应展示的公告。
  ///
  /// 返回 null 的四种情况（都属正常，不该报错）：
  /// - 后端没配置公告 / 公告被停用 / 版本范围不匹配
  /// - 网络不可达
  /// - 本机已读过这一条
  /// - 用户本次会话内点了「稍后看」，尚未到重试时间
  Future<CloudAnnouncement?> fetchPending({
    required String version,
    String platform = 'android',
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '${CloudConfig.baseUrl}/api/announcement',
        queryParameters: {'platform': platform, 'version': version},
      );
      final raw = resp.data?['announcement'];
      if (raw is! Map) return null;
      final ann = CloudAnnouncement.fromJson(Map<String, dynamic>.from(raw));
      if (ann.id.isEmpty || ann.content.trim().isEmpty) return null;

      // 已读过同一版本 → 不再弹
      if (_prefs.getString('$_seenPrefix${ann.seenKey}') != null) return null;

      // 本次会话点过「稍后看」：6 小时内不重复打扰
      final snoozed = _prefs.getInt(_snoozedKey) ?? 0;
      if (snoozed > DateTime.now().millisecondsSinceEpoch) return null;

      return ann;
    } catch (_) {
      // 公告拉不到不是错误（离线、后端未部署公告表等），静默跳过
      return null;
    }
  }

  /// 标记已读。看完点「我知道了」调用，下次不再打扰。
  Future<void> markSeen(CloudAnnouncement ann) async {
    await _prefs.setString('$_seenPrefix${ann.seenKey}', '1');
  }

  /// 点「稍后看」：静默 6 小时后再提醒，不标记已读。
  Future<void> snooze() async {
    await _prefs.setInt(
      _snoozedKey,
      DateTime.now().millisecondsSinceEpoch() + 6 * 3600 * 1000,
    );
  }
}
