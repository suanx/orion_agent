import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'builtin_mcp.dart';
import 'database.dart';
import 'mcp_client.dart';
import 'tools.dart';

/// MCP 服务器管理：配置 CRUD + 启动时连接并把工具注册进 ToolRegistry。
class McpService {
  McpService(this._db, this._registry);

  final AppDatabase _db;
  final ToolRegistry _registry;

  /// 当前存活的连接，key 为服务器 id。重连/停用/删除前必须 close 旧 client
  /// （其底层 Dio），否则每次重连都会泄漏一个持有打开连接的 Dio 实例。
  final Map<String, McpClient> _clients = {};

  Future<List<McpServer>> listServers() async {
    final rows = await (_db.select(_db.mcpServers)
          ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
        .get();
    return rows;
  }

  Future<void> addServer(String name, String url) async {
    final row = McpServer(
      id: uniqueId('mcp'),
      name: name,
      url: url,
      enabled: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.into(_db.mcpServers).insert(McpServersCompanion(
          id: Value(row.id),
          name: Value(row.name),
          url: Value(row.url),
          enabled: Value(row.enabled),
          createdAt: Value(row.createdAt),
        ));
  }

  Future<void> removeServer(String id) async {
    await (_db.delete(_db.mcpServers)..where((s) => s.id.equals(id))).go();
    _clients.remove(id)?.close();
  }

  /// 修改服务器名称/URL。改名后工具注册前缀（按旧名 sanitize）随之失效、
  /// URL 变更后旧 client 也不可用——这里只负责落库与断开旧连接，
  /// 重连（connectAll 会按新名/新 URL 重新注册工具）由调用方触发。
  Future<void> updateServer(String id,
      {required String name, required String url}) async {
    await (_db.update(_db.mcpServers)..where((s) => s.id.equals(id)))
        .write(McpServersCompanion(name: Value(name), url: Value(url)));
    _clients.remove(id)?.close();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await (_db.update(_db.mcpServers)..where((s) => s.id.equals(id)))
        .write(McpServersCompanion(enabled: Value(enabled)));
    if (!enabled) _clients.remove(id)?.close();
  }

  /// 连接所有启用的服务器并注册其工具，返回新注册的工具数。
  /// 单个服务器失败（超时/协议错误）会被跳过，不影响其它服务器。
  ///
  /// **内置服务器先于用户配置连接**（builtinMcpServers 顺序即优先级）：
  /// 先注册者在系统提示词的扩展工具清单中排在前面，与用户自配功能重叠时
  /// 优先被调用。
  Future<int> connectAll({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final servers = await listServers();

    // 先注销本服务此前注册的全部工具，否则重连是【静默空操作】：
    // register() 遇到同名工具会直接跳过，于是旧 McpTool（持有旧 client / 旧 Dio）
    // 被永久保留，新建的连接被丢弃。用户反复点「连接」或把开关 off→on，
    // 工具调用仍走旧会话。同样，停用/删除服务器后工具也不会消失，
    // 用户明明关掉了它，Agent 却还在调用。
    for (final b in builtinMcpServers) {
      _registry.unregisterPrefix('${McpTool.sanitizePublic(b.name)}__');
      _clients.remove(b.id)?.close();
    }
    for (final s in servers) {
      _registry.unregisterPrefix('${McpTool.sanitizePublic(s.name)}__');
      // 旧连接先 close 再重建：不 close 的话，每次重连都会泄漏一个 Dio。
      _clients.remove(s.id)?.close();
    }

    var count = 0;
    for (final b in builtinMcpServers) {
      count += await _connectOne(b.id, b.name, b.url, timeout);
    }
    for (final s in servers) {
      if (!s.enabled) continue;
      count += await _connectOne(s.id, s.name, s.url, timeout);
    }
    return count;
  }

  /// 连接单个服务器并注册工具（工具名带 `前缀__`），失败返回 0 不抛出。
  Future<int> _connectOne(
      String id, String name, String url, Duration timeout) async {
    // 每次连接独立 Dio，失败时必须显式关闭，否则重连会累积连接。
    final dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
    ));
    try {
      final client = McpClient(
        dio: dio,
        name: name,
        url: url,
      );
      // 超时由 Dio 自身负责（connectTimeout 8s + 各请求的 receiveTimeout，
      // 见 McpClient），不再用 Future.timeout 包装——它不会取消底层请求，
      // 还会把 30s 的 tools/list 硬砍成 8s。
      await client.initialize();
      final tools = await client.listTools();
      final prefix = '${McpTool.sanitizePublic(name)}__';
      var count = 0;
      for (final info in tools) {
        _registry.register(McpTool(client: client, info: info, prefix: prefix));
        count++;
      }
      _clients[id] = client;
      return count;
    } catch (e) {
      // 原来 catch (_) 把「URL 写错 / 鉴权失败 / DNS 失败 / 协议不兼容 / 超时」
      // 全部归为同一结果且不打日志，界面只能显示"没有连接到可用的 MCP 服务器"，
      // 无法区分配置错误与服务暂时不可达。这里至少留下可排查的线索。
      debugPrint('MCP 服务器「$name」($url) 连接失败：$e');
      dio.close(force: true);
      return 0;
    }
  }
}
