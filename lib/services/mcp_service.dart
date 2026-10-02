import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'database.dart';
import 'mcp_client.dart';
import 'tools.dart';

/// MCP 服务器管理：配置 CRUD + 启动时连接并把工具注册进 ToolRegistry。
class McpService {
  McpService(this._db, this._registry);

  final AppDatabase _db;
  final ToolRegistry _registry;

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
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await (_db.update(_db.mcpServers)..where((s) => s.id.equals(id)))
        .write(McpServersCompanion(enabled: Value(enabled)));
  }

  /// 连接所有启用的服务器并注册其工具，返回新注册的工具数。
  /// 单个服务器失败（超时/协议错误）会被跳过，不影响其它服务器。
  Future<int> connectAll({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final servers = await listServers();

    // 先注销本服务此前注册的全部工具，否则重连是【静默空操作】：
    // register() 遇到同名工具会直接跳过，于是旧 McpTool（持有旧 client / 旧 Dio）
    // 被永久保留，新建的连接被丢弃。用户反复点「连接」或把开关 off→on，
    // 工具调用仍走旧会话。同样，停用/删除服务器后工具也不会消失，
    // 用户明明关掉了它，Agent 却还在调用。
    for (final s in servers) {
      _registry.unregisterPrefix('${McpTool.sanitizePublic(s.name)}__');
    }

    var count = 0;
    for (final s in servers) {
      if (!s.enabled) continue;
      // 每次连接独立 Dio，失败时必须显式关闭，否则重连会累积连接。
      final dio = Dio(BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
      ));
      try {
        final client = McpClient(
          dio: dio,
          name: s.name,
          url: s.url,
        );
        await client.initialize().timeout(timeout * 2);
        final tools = await client.listTools().timeout(timeout);
        final prefix = '${McpTool.sanitizePublic(s.name)}__';
        for (final info in tools) {
          _registry
              .register(McpTool(client: client, info: info, prefix: prefix));
          count++;
        }
      } catch (e) {
        // 原来 catch (_) 把「URL 写错 / 鉴权失败 / DNS 失败 / 协议不兼容 / 超时」
        // 全部归为同一结果且不打日志，界面只能显示"没有连接到可用的 MCP 服务器"，
        // 无法区分配置错误与服务暂时不可达。这里至少留下可排查的线索。
        debugPrint('MCP 服务器「${s.name}」(${s.url}) 连接失败：$e');
        dio.close(force: true);
      }
    }
    return count;
  }
}
