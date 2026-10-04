import 'dart:convert';

import 'package:dio/dio.dart';

import 'tools.dart';

/// 极简 MCP 客户端（Streamable HTTP 传输）：JSON-RPC 2.0 over POST。
/// 支持 application/json 与 text/event-stream 两种响应格式。
class McpClient {
  McpClient({required Dio dio, required this.name, required this.url})
      : _dio = dio;

  static const _protocolVersion = '2024-11-05';

  /// Streamable HTTP 规范：initialize 之后的所有请求都必须回传的协议版本头。
  static const _protocolVersionHeader = '2025-06-18';

  final Dio _dio;
  final String name;
  final String url;

  int _nextId = 1;

  /// initialize 响应头里的会话标识；按规范实现的服务器（官方 SDK 默认）
  /// 要求后续每个请求原样回传，否则第二个请求就会 404/400。
  String? _sessionId;

  /// 是否已完成 initialize（决定是否携带协议版本头）。
  bool _initialized = false;

  Options _buildOptions({Duration? receiveTimeout}) => Options(
        responseType: ResponseType.plain,
        receiveTimeout: receiveTimeout,
        headers: {
          'Accept': 'application/json, text/event-stream',
          'Content-Type': 'application/json',
          if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
          if (_initialized) 'MCP-Protocol-Version': _protocolVersionHeader,
        },
      );

  /// 断开连接：关闭底层 Dio，释放连接。重连/删除服务器前必须调用，
  /// 否则旧连接会随每次重连不断累积。
  void close() => _dio.close(force: true);

  Future<void> initialize() async {
    await _rpc('initialize', {
      'protocolVersion': _protocolVersion,
      'capabilities': {},
      'clientInfo': {'name': 'orion_agent', 'version': '0.1.0'},
    });
    _initialized = true;
    await _notify('notifications/initialized');
  }

  Future<List<Map<String, dynamic>>> listTools() async {
    // tools/list 服务器侧可能要枚举并探测工具，放宽到 30s。
    final result = await _rpc('tools/list', {},
        receiveTimeout: const Duration(seconds: 30));
    return (result?['tools'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// 调用工具并拼接全部文本内容返回。
  ///
  /// 工具（网页抓取、代码执行等）本身可能跑几分钟，绝不能复用
  /// 连接级的 8s receiveTimeout，单独放宽到 5 分钟。
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final result = await _rpc('tools/call', {
      'name': toolName,
      'arguments': args,
    }, receiveTimeout: const Duration(minutes: 5));
    final content = result?['content'] as List? ?? const [];
    final text = content
        .whereType<Map<String, dynamic>>()
        .where((c) => c['type'] == 'text')
        .map((c) => c['text']?.toString() ?? '')
        .join('\n');
    if (text.isNotEmpty) return text;
    return (result?['isError'] == true) ? 'MCP 工具返回错误' : '（工具无文本输出）';
  }

  Future<Map<String, dynamic>?> _rpc(
      String method, Map<String, dynamic> params,
      {Duration? receiveTimeout, bool retryOnSessionLoss = true}) async {
    Response<String> resp;
    try {
      resp = await _dio.post<String>(
        url,
        data: {
          'jsonrpc': '2.0',
          'id': _nextId++,
          'method': method,
          'params': params,
        },
        options: _buildOptions(receiveTimeout: receiveTimeout),
      );
    } on DioException catch (e) {
      // 服务器重启/会话过期会丢掉我们的会话（404）。清空 sessionId
      // 重新走一次 initialize 握手，再重试当前请求（只重试一次防循环）。
      if (retryOnSessionLoss &&
          _sessionId != null &&
          e.response?.statusCode == 404) {
        _sessionId = null;
        _initialized = false;
        await initialize();
        return _rpc(method, params,
            receiveTimeout: receiveTimeout, retryOnSessionLoss: false);
      }
      rethrow;
    }
    // 会话标识可能出现在任意响应头（主要在 initialize），捕获后供后续请求回传。
    final sid = resp.headers.value('mcp-session-id');
    if (sid != null && sid.isNotEmpty) _sessionId = sid;
    final body = resp.data ?? '';
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      decoded = body; // SSE 等纯文本
    }
    final json = parseRpcBody(decoded);
    if (json == null) throw Exception('MCP 响应解析失败');
    if (json['error'] != null) throw Exception('MCP 错误：${json['error']}');
    return json['result'] is Map<String, dynamic>
        ? json['result'] as Map<String, dynamic>
        : null;
  }

  Future<void> _notify(String method) async {
    try {
      await _dio.post<String>(
        url,
        data: {'jsonrpc': '2.0', 'method': method, 'params': {}},
        options: _buildOptions(),
      );
    } catch (_) {
      // 通知失败不阻断流程
    }
  }

  /// 从响应体提取 JSON-RPC 响应对象；找不到带 id 的响应时返回 null。
  static Map<String, dynamic>? parseRpcBody(dynamic body) {
    if (body is Map) {
      final m = Map<String, dynamic>.from(body);
      return m['id'] != null ? m : null;
    }
    if (body is List) return null;
    if (body is String) {
      // 先尝试整体是 JSON
      try {
        final d = jsonDecode(body);
        if (d is Map) {
          final m = Map<String, dynamic>.from(d);
          return m['id'] != null ? m : null;
        }
      } catch (_) {}
      // 否则按 SSE 解析 data: 行
      for (final line in body.split('\n')) {
        final l = line.trim();
        if (!l.startsWith('data:')) continue;
        try {
          final d = jsonDecode(l.substring(5).trim());
          if (d is Map && d['id'] != null) {
            return Map<String, dynamic>.from(d);
          }
        } catch (_) {}
      }
    }
    return null;
  }
}

/// 把 MCP 工具适配成本地 Tool 接口。名字加服务器前缀避免冲突，
/// 并清理成 OpenAI function name 允许的字符（[a-zA-Z0-9_-]）。
class McpTool extends Tool {
  McpTool({required this.client, required Map<String, dynamic> info, String prefix = ''})
      : _info = info,
        _name = '$prefix${_sanitize(info['name']?.toString() ?? '')}';

  final McpClient client;
  final Map<String, dynamic> _info;
  final String _name;

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  /// 供外部（服务器名前缀等）复用的公开清理函数。
  static String sanitizePublic(String s) => _sanitize(s);

  /// MCP 侧的原始工具名（调用时使用）。
  String get originalName => _info['name']?.toString() ?? '';

  @override
  String get name => _name;

  @override
  String get description {
    final d = _info['description']?.toString() ?? '';
    return d.isEmpty
        ? 'MCP 工具 $originalName（来自 ${client.name}）'
        : d;
  }

  @override
  Map<String, dynamic> get parameters {
    final schema = _info['inputSchema'];
    if (schema is Map<String, dynamic>) return schema;
    return {'type': 'object', 'properties': const {}};
  }

  @override
  Future<String> execute(Map<String, dynamic> args) =>
      client.callTool(originalName, args);
}
