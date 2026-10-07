import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_config.dart';

/// orion_agent_cloud 云端后端（EdgeOne Pages + Turso）客户端。
///
/// 职责：
/// - 账号（注册/登录/刷新/登出）、设备管理
/// - 授权状态查询（套餐由管理台直接设置, 授权已改为账号授权）
/// - 搜索/抓取中继（国内网络下 DuckDuckGo 不可达，经云端边缘节点代理）
/// - 更新清单（/update/check，国内可达的版本分发）
///
/// 令牌存储：与模型 API Key 同级，进 FlutterSecureStorage（Keystore 加密）。
/// JWT 2 小时过期：请求遇 401 自动用 refresh token 续期一次后重试；
/// refresh token 30 天、一次性轮换（旧令牌复用即失效，服务端已强制）。
class CloudService {
  CloudService(this._prefs, this._secure);

  static const _deviceIdKey = 'cloud_device_id';
  static const _tokensKey = 'cloud_tokens';
  static const _deviceTokenKey = 'cloud_device_token';
  static const _emailKey = 'cloud_email';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    // 401/429 等业务状态由调用方读取响应体处理，不抛 DioException。
    validateStatus: (s) => s != null && s < 500,
  ));

  CloudTokens? _tokens;
  String? _deviceToken;

  // ---------------- 配置 ----------------

  /// 云端后端地址：**写死在 CloudConfig**（不暴露给用户配置）。
  /// 换后端地址改 lib/services/cloud_config.dart 的 baseUrl 一处即可。
  String get baseUrl => CloudConfig.baseUrl;

  bool get isConfigured => CloudConfig.baseUrl.isNotEmpty;

  bool get isLoggedIn => _tokens != null;

  String get userId => _tokens?.userId ?? '';

  /// 登录邮箱。后端登录/注册响应不回传邮箱，成功时本地记录一份
  /// （个人中心展示用），登出时清除。
  String? get email {
    final v = _prefs.getString(_emailKey)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 当前套餐（来自最近一次登录/注册响应；精确值以 fetchAccountInfo 为准）。
  String get plan => _tokens?.plan ?? 'free';

  /// 设备标识：首次生成后持久化，激活/登录/设备管理都用它。
  String get deviceId {
    var id = _prefs.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      id = 'dev_${DateTime.now().millisecondsSinceEpoch}_${_randHex(8)}';
      _prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  // ---------------- 令牌与恢复 ----------------

  /// 启动时恢复登录态。只读本地不联网（联网刷新由首次请求时的 401 路径触发），
  /// 失败静默——恢复不了就当未登录，不阻断启动。
  Future<void> restore() async {
    try {
      final raw = await _secure.read(key: _tokensKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) {
        _tokens = CloudTokens.fromJson(map);
      }
    } catch (_) {
      _tokens = null;
    }
  }

  Future<void> _saveTokens(CloudTokens? t) async {
    _tokens = t;
    if (t == null) {
      await _secure.delete(key: _tokensKey);
    } else {
      await _secure.write(key: _tokensKey, value: jsonEncode(t.toJson()));
    }
  }

  // ---------------- 账号 ----------------

  Future<void> register(String email, String password) async {
    final data = await _post('/api/auth/register', {
      'email': email.trim(),
      'password': password,
      'deviceId': deviceId,
      'deviceName': _deviceName,
    });
    await _saveTokens(CloudTokens.fromJson(data));
    await _prefs.setString(_emailKey, email.trim().toLowerCase());
  }

  Future<void> login(String email, String password) async {
    final data = await _post('/api/auth/login', {
      'email': email.trim(),
      'password': password,
      'deviceId': deviceId,
      'deviceName': _deviceName,
    });
    await _saveTokens(CloudTokens.fromJson(data));
    await _prefs.setString(_emailKey, email.trim().toLowerCase());
  }

  /// 登出：尽力通知服务端吊销 refresh token，无论成败本地令牌都清掉。
  Future<void> logout() async {
    final rt = _tokens?.refreshToken;
    _tokens = null;
    _deviceToken = null;
    await _secure.delete(key: _tokensKey);
    await _secure.delete(key: _deviceTokenKey);
    await _prefs.remove(_emailKey);
    if (rt != null && baseUrl != null) {
      try {
        await _dio.post('$baseUrl/api/auth/logout',
            data: {'refreshToken': rt});
      } catch (_) {
        // 本地已清除，网络失败不影响登出
      }
    }
  }

  // ---------------- 授权与账号信息 ----------------

  /// 账号 + 套餐 + 今日用量（云端个人中心展示用）。
  Future<CloudAccountInfo> fetchAccountInfo() async {
    final data = await _authedGet('/api/license/status');
    final usage = <String, int>{};
    final today = data['usageToday'];
    if (today is Map) {
      today.forEach((k, v) => usage[k.toString()] = (v as num?)?.toInt() ?? 0);
    }
    final licenses = (data['licenses'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => CloudActivatedLicense.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    return CloudAccountInfo(
      userId: data['userId']?.toString() ?? '',
      plan: data['plan']?.toString() ?? 'free',
      planExpiresAt: (data['planExpiresAt'] as num?)?.toInt(),
      usageToday: usage,
      licenses: licenses,
    );
  }

  Future<List<CloudDevice>> fetchDevices() async {
    final data = await _authedGet('/api/auth/devices');
    final list = data['devices'];
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(CloudDevice.fromJson)
        .toList();
  }

  Future<void> unbindDevice(String deviceId) =>
      _authedDelete('/api/auth/devices/${Uri.encodeComponent(deviceId)}');

  Future<String> createDeviceToken() async {
    final data = await _authedPost('/api/auth/device-token', {
      'deviceId': deviceId,
      'deviceName': _deviceName,
    });
    return data['deviceToken']?.toString() ?? '';
  }

  /// 换长期设备令牌（MCP 配置用）。缓存复用：令牌无过期时间，
  /// 反复登录不应生成新令牌（旧令牌不会自动吊销，会越积越多）。
  Future<String> getOrCreateDeviceToken() async {
    if (_deviceToken != null) return _deviceToken!;
    final cached = await _secure.read(key: _deviceTokenKey);
    if (cached != null && cached.isNotEmpty) {
      _deviceToken = cached;
      return cached;
    }
    final token = await createDeviceToken();
    if (token.isNotEmpty) {
      _deviceToken = token;
      await _secure.write(key: _deviceTokenKey, value: token);
    }
    return token;
  }

  // ---------------- 搜索/抓取中继 ----------------

  /// 经云端中继搜索。返回格式化结果文本；null = 中继不可用（未配置/未登录/
  /// 网络失败），调用方应回退直连。配额用尽等业务错误会以「错误：…」文本返回，
  /// 让 Agent 能向用户解释，而不是静默降级到必然失败的直连。
  Future<String?> relaySearch(String query) async {
    // 未配置/未登录：返回 null 让调用方回退直连（不算错误）
    if (!isConfigured || !isLoggedIn) return null;
    try {
      final data = await _authedGet(
          '/api/relay/search?q=${Uri.encodeQueryComponent(query)}');
      final formatted = data['formatted']?.toString() ?? '';
      if (formatted.isEmpty) return null;
      return '[云端搜索] $formatted';
    } on CloudException catch (e) {
      return '错误：云端搜索失败（${e.message}）';
    } catch (_) {
      return null; // 网络不可达等 → 回退直连
    }
  }

  /// 经云端中继抓取网页正文。
  Future<String?> relayFetch(String url) async {
    if (!isConfigured || !isLoggedIn) return null;
    try {
      final data =
          await _authedGet('/api/relay/fetch?url=${Uri.encodeComponent(url)}');
      final title = data['title']?.toString() ?? '';
      final content = data['content']?.toString() ?? '';
      if (content.isEmpty) return null;
      final buf = StringBuffer();
      if (title.isNotEmpty) buf.writeln('# $title');
      buf.writeln('来源: ${data['url'] ?? url}');
      buf.writeln();
      buf.write(content);
      return buf.toString();
    } on CloudException catch (e) {
      return '错误：云端抓取失败（${e.message}）';
    } catch (_) {
      return null;
    }
  }

  // ---------------- 更新清单 ----------------

  /// GET /update/check（无需鉴权）。返回原始 JSON；失败返回 null，
  /// 由 UpdateService 回退 GitHub Releases。
  Future<Map<String, dynamic>?> checkUpdate(String currentVersion) async {
    final base = baseUrl;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '$base/api/update/check',
        queryParameters: {'platform': 'android', 'current': currentVersion},
      );
      return resp.data;
    } catch (_) {
      return null;
    }
  }

  // ---------------- HTTP 基础设施 ----------------

  String get _deviceName => 'Android/${deviceId.substring(0, 8)}';

  String _randHex(int bytes) {
    final values = List<int>.generate(bytes, (_) => Random.secure().nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 统一 POST：非 2xx 时从响应体提取 error.message 抛 CloudException。
  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final base = _requireBaseUrl();
    final resp = await _dio.post<Map<String, dynamic>>('$base$path', data: body);
    return _unwrap(resp);
  }

  /// 带鉴权 GET：401 时用 refresh token 续期一次后重试。
  Future<Map<String, dynamic>> _authedGet(String path) async =>
      _authed('get', path, null);

  Future<Map<String, dynamic>> _authedPost(String path, Map<String, dynamic> body) async =>
      _authed('post', path, body);

  Future<Map<String, dynamic>> _authedDelete(String path) async =>
      _authed('delete', path, null);

  Future<Map<String, dynamic>> _authed(
      String method, String path, Map<String, dynamic>? body,
      {bool retried = false}) async {
    final tokens = _tokens;
    if (tokens == null) {
      throw const CloudException('未登录');
    }
    final base = _requireBaseUrl();
    final Response<Map<String, dynamic>> resp;
    try {
      resp = await _dio.request<Map<String, dynamic>>(
        '$base$path',
        data: body,
        options: Options(method: method, headers: {
          'Authorization': 'Bearer ${tokens.accessToken}',
        }),
      );
    } on DioException catch (e) {
      throw CloudException('网络错误：${e.message ?? e.type.name}');
    }
    if (resp.statusCode == 401 && !retried) {
      // access token 过期 → 续期后重试一次
      final refreshed = await _refresh();
      if (refreshed) {
        return _authed(method, path, body, retried: true);
      }
      throw const CloudException('登录已过期，请重新登录');
    }
    return _unwrap(resp);
  }

  Future<bool> _refresh() async {
    final rt = _tokens?.refreshToken;
    if (rt == null) return false;
    final base = baseUrl;
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '$base/api/auth/refresh',
        data: {'refreshToken': rt},
      );
      if (resp.statusCode != 200 || resp.data == null) {
        // refresh token 已失效（轮换后复用/过期）→ 清除登录态
        await _saveTokens(null);
        return false;
      }
      await _saveTokens(CloudTokens.fromJson(resp.data!));
      return true;
    } catch (_) {
      return false;
    }
  }

  String _requireBaseUrl() => baseUrl;

  Map<String, dynamic> _unwrap(Response<Map<String, dynamic>> resp) {
    final data = resp.data;
    if (data == null) {
      throw CloudException('服务无响应（HTTP ${resp.statusCode}）');
    }
    if (resp.statusCode != null && resp.statusCode! >= 200 && resp.statusCode! < 300) {
      return data;
    }
    final err = data['error'];
    final msg = err is Map ? (err['message']?.toString() ?? '请求失败') : '请求失败';
    throw CloudException(msg);
  }
}

class CloudTokens {
  CloudTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.plan,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String plan;

  factory CloudTokens.fromJson(Map<String, dynamic> json) => CloudTokens(
        accessToken: json['accessToken']?.toString() ?? '',
        refreshToken: json['refreshToken']?.toString() ?? '',
        userId: json['userId']?.toString() ?? '',
        plan: json['plan']?.toString() ?? 'free',
      );

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'userId': userId,
        'plan': plan,
      };
}

class CloudAccountInfo {
  const CloudAccountInfo({
    required this.userId,
    required this.plan,
    required this.planExpiresAt,
    required this.usageToday,
    this.licenses = const [],
  });

  final String userId;
  final String plan;
  final int? planExpiresAt;
  final Map<String, int> usageToday;

  /// 已激活的卡密记录（按激活时间排序）。
  final List<CloudActivatedLicense> licenses;
}

/// 一条已激活的卡密记录。
class CloudActivatedLicense {
  const CloudActivatedLicense({
    required this.code,
    required this.plan,
    this.durationDays,
    this.boundAt,
  });

  final String code;
  final String plan;
  final int? durationDays;
  final int? boundAt;

  factory CloudActivatedLicense.fromJson(Map<String, dynamic> json) =>
      CloudActivatedLicense(
        code: json['code']?.toString() ?? '',
        plan: json['plan']?.toString() ?? '',
        durationDays: (json['durationDays'] as num?)?.toInt(),
        boundAt: (json['boundAt'] as num?)?.toInt(),
      );
}

class CloudDevice {
  const CloudDevice({
    required this.deviceId,
    required this.deviceName,
    required this.isCurrent,
    this.activatedAt,
    this.lastSeenAt,
  });

  final String deviceId;
  final String deviceName;
  final bool isCurrent;
  final int? activatedAt;
  final int? lastSeenAt;

  factory CloudDevice.fromJson(Map<String, dynamic> json) => CloudDevice(
        deviceId: json['deviceId']?.toString() ?? '',
        deviceName: json['deviceName']?.toString() ?? '',
        isCurrent: json['current'] == true,
        activatedAt: (json['activatedAt'] as num?)?.toInt(),
        lastSeenAt: (json['lastSeenAt'] as num?)?.toInt(),
      );
}

/// 云端业务错误（服务端 error.message 的中文文案直接透传）。
class CloudException implements Exception {
  const CloudException(this.message);
  final String message;

  @override
  String toString() => message;
}
