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

  /// Beta 通道：releases 列表（按 created_at 倒序，含 pre-release）。
  /// 取前 5 条：预发布可能连续多个，足够覆盖到第一条比当前新的版本。
  static const _listApi =
      'https://api.github.com/repos/suanx/orion_agent/releases?per_page=5';

  static const _defaultTimeout = Duration(seconds: 15);

  final CloudService? _cloud;
  Dio? _dioInstance;
  Dio get _dio => _dioInstance ??= Dio(BaseOptions(connectTimeout: _defaultTimeout));

  /// 检查结果：null 表示已是最新或检查失败（自动检查应当静默）。
  ///
  /// [includePrereleases] = Beta 通道（关于页「加入 Beta 测试」开关）：
  /// 云端 /update/check 没有「预发布」概念，开启后直查 GitHub releases
  /// 列表（含 pre-release、不含 draft），取最新一条带 APK 且比当前新的。
  Future<UpdateInfo?> checkForUpdate(String currentVersion,
      {Duration timeout = _defaultTimeout,
      bool includePrereleases = false}) async {
    if (includePrereleases) {
      return _checkViaGithubList(currentVersion, timeout: timeout);
    }
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
      return parseReleaseEntry(data, currentVersion: currentVersion);
    } catch (_) {
      return null;
    }
  }

  /// Beta 通道：查 releases 列表（含 pre-release），从新到旧找第一条
  /// 比 [currentVersion] 新且带 APK 的发布。
  ///
  /// 顺序遍历全部 5 条而不是只看第一条：预发布可能不带 APK 或带也可能
  /// 仍是当前版本（重复推包），跳过它们继续向后找稳定版兜底。
  Future<UpdateInfo?> _checkViaGithubList(String currentVersion,
      {required Duration timeout}) async {
    try {
      final resp = await _dio.get<List<dynamic>>(
        _listApi,
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: timeout,
        ),
      );
      final list = resp.data;
      if (list == null) return null;
      for (final item in list) {
        final info = parseReleaseEntry(item, currentVersion: currentVersion);
        if (info != null) return info;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 把一条 GitHub release JSON 解析为 UpdateInfo；不可用（draft / 无
  /// APK / 不比 [currentVersion] 新）返回 null。
  ///
  /// 纯函数（无网络），供单元测试直接构造 JSON 断言。
  /// ⚠️ 版本比较依赖「逐段数字」规则，beta 发布的 tag 仍须是纯 vX.Y.Z
  /// 数字（预发布语义用 GitHub 的 pre-release 勾选表达），带 `-beta.1`
  /// 之类后缀会被解析成 0 而比较错乱。
  static UpdateInfo? parseReleaseEntry(dynamic item,
      {required String currentVersion}) {
    if (item is! Map) return null;
    final m = item.cast<String, dynamic>();
    if (m['draft'] == true) return null; // draft 无 APK 且非公开
    final tag = (m['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (tag.isEmpty) return null;
    if (!isNewer(tag, currentVersion)) return null;
    String? apkUrl;
    final assets = m['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final am = a.cast<String, dynamic>();
        final name = am['name'] as String? ?? '';
        if (name.toLowerCase().endsWith('.apk')) {
          apkUrl = am['browser_download_url'] as String?;
          break;
        }
      }
    }
    final changelog = (m['body'] as String? ?? '').trim();
    return UpdateInfo(
      version: tag,
      changelog: changelog.isEmpty ? null : changelog,
      apkUrl: apkUrl,
    );
  }

  /// 版本比较：逐段数字比较，段数不足补 0。'v' 前缀由调用方剥掉。
  ///
  /// 每段容忍非数字后缀（取前导数字）：Beta 通道版本号形如 `0.2.13-beta`，
  /// 第三段 '13-beta' 解析为 13。这样：
  /// - '0.2.13-beta' > '0.2.12' ✓（Beta 用户能收到测试版）
  /// - '0.2.13' vs '0.2.13-beta' 相等 ✓（同号稳定版不再提示 Beta 用户更新）
  static bool isNewer(String remote, String local) {
    List<int> parse(String v) => v.split('.').map((s) {
          final m = RegExp(r'^(\d+)').firstMatch(s.trim());
          return m == null ? 0 : int.parse(m.group(1)!);
        }).toList();
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
