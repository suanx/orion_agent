import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

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
    var count = 0;
    for (final s in await listServers()) {
      if (!s.enabled) continue;
      try {
        final client = McpClient(
          dio: Dio(BaseOptions(
            connectTimeout: timeout,
            receiveTimeout: timeout,
          )),
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
      } catch (_) {
        // 忽略不可用的服务器
      }
    }
    return count;
  }
}
