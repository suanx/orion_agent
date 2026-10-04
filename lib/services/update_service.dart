import 'package:dio/dio.dart';

import 'cloud_service.dart';

/// 应用内更新检查。
///
/// 优先走自建云端（orion_agent_cloud 的 /update/check，国内可达、APK 下载快），
/// 未配置云端或云端检查失败时回退 GitHub Releases latest。
/// 弹窗与「关于」页共用同一实现，避免两套解析将来改岔。
/// 版本号比较规则：逐段数字比较，段数不足补 0。
class UpdateService {
  UpdateService({CloudService? cloud}) : _cloud = cloud;

  static const _latestApi =
      'https://api.github.com/repos/suanx/orion_agent/releases/latest';

  static const _defaultTimeout = Duration(seconds: 15);

  final CloudService? _cloud;
  Dio? _dioInstance;
  Dio get _dio => _dioInstance ??= Dio(BaseOptions(connectTimeout: _defaultTimeout));

  /// 检查结果：null 表示已是最新或检查失败（自动检查应当静默）。
  Future<UpdateInfo?> checkForUpdate(String currentVersion,
      {Duration timeout = _defaultTimeout}) async {
    // 云端优先：国内网络下 GitHub API 与 Releases 下载都不可靠
    final viaCloud = await _checkViaCloud(currentVersion);
    if (viaCloud != null) return viaCloud;
    return _checkViaGithub(currentVersion, timeout: timeout);
  }

  Future<UpdateInfo?> _checkViaCloud(String currentVersion) async {
    final cloud = _cloud;
    if (cloud == null || !cloud.isConfigured) return null;
    try {
      final data = await cloud.checkUpdate(currentVersion);
      if (data == null || data['updateAvailable'] != true) return null;
      final latest = data['latest']?.toString() ?? '';
      if (latest.isEmpty || !isNewer(latest, currentVersion)) return null;
      return UpdateInfo(
        version: latest,
        changelog: (data['notes']?.toString() ?? '').trim().isEmpty
            ? null
            : data['notes']?.toString(),
        apkUrl: (data['apkUrl']?.toString() ?? '').isEmpty
            ? null
            : data['apkUrl']?.toString(),
      );
    } catch (_) {
      return null; // 云端失败静默回退 GitHub
    }
  }

  Future<UpdateInfo?> _checkViaGithub(String currentVersion,
      {required Duration timeout}) async {
    try {
      // 超时交给 Dio 的 connect/receiveTimeout 配置：原来的 Future.timeout
      // 只是放弃等待，底层请求仍会继续跑，连接无法取消。
      final resp = await _dio.get<Map<String, dynamic>>(
        _latestApi,
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: timeout,
        ),
      );
      final data = resp.data;
      if (data == null) return null;
      final tag = (data['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (tag.isEmpty) return null;
      if (!isNewer(tag, currentVersion)) return null;
      String? apkUrl;
      final assets = data['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is! Map) continue;
          final m = a.cast<String, dynamic>();
          final name = m['name'] as String? ?? '';
          if (name.toLowerCase().endsWith('.apk')) {
            apkUrl = m['browser_download_url'] as String?;
            break;
          }
        }
      }
      final changelog = (data['body'] as String? ?? '').trim();
      return UpdateInfo(
        version: tag,
        changelog: changelog.isEmpty ? null : changelog,
        apkUrl: apkUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// 版本比较：逐段数字比较，段数不足补 0。'v' 前缀由调用方剥掉。
  static bool isNewer(String remote, String local) {
    List<int> parse(String v) =>
        v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final a = parse(remote);
    final b = parse(local);
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}

/// 一次检查更新发现的新版本信息。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    this.changelog,
    this.apkUrl,
  });

  final String version;
  final String? changelog;

  /// release 附带的 APK 下载地址；null 时只能引导去 releases 页。
  final String? apkUrl;
}
