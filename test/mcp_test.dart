import 'package:drift/native.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/database.dart';
import 'package:orion_agent/services/mcp_client.dart';
import 'package:orion_agent/services/mcp_service.dart';
import 'package:orion_agent/services/memory_service.dart';
import 'package:orion_agent/services/tools.dart';

class _EchoTool extends Tool {
  _EchoTool(this.n);
  final String n;
  @override
  String get name => n;
  @override
  String get description => 'echo';
  @override
  Map<String, dynamic> get parameters => {'type': 'object', 'properties': {}};
  @override
  Future<String> execute(Map<String, dynamic> args) async => 'ok';
}

void main() {
  group('McpClient.parseRpcBody', () {
    test('纯 JSON Map 直接返回', () {
      final r = McpClient.parseRpcBody({'jsonrpc': '2.0', 'id': 1, 'result': {}});
      expect(r?['id'], 1);
    });

    test('JSON 字符串解析', () {
      final r = McpClient.parseRpcBody('{"jsonrpc":"2.0","id":2,"result":{}}');
      expect(r?['id'], 2);
    });

    test('SSE data 行解析', () {
      const sse = 'event: message\n'
          'data: {"jsonrpc":"2.0","id":7,"result":{"tools":[]}}\n\n'
          'data: [DONE]\n';
      final r = McpClient.parseRpcBody(sse);
      expect(r?['id'], 7);
    });

    test('无 id 的通知响应与垃圾输入返回 null', () {
      expect(McpClient.parseRpcBody({'jsonrpc': '2.0', 'method': 'x'}), isNull);
      expect(McpClient.parseRpcBody('not json at all'), isNull);
      expect(McpClient.parseRpcBody(null), isNull);
    });
  });

  group('McpTool 适配', () {
    // 这些用例不发起网络请求，Dio 只用于构造
    final client = McpClient(dio: Dio(), name: '文件服务', url: 'http://x/mcp');

    test('名字加前缀并清理非法字符', () {
      final tool = McpTool(
        client: client,
        info: {
          'name': 'read.file 文件',
          'description': '读取文件',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
          },
        },
        prefix: 'ws__',
      );
      // 前缀保留、非法字符全部替换为 _，且整体符合 OpenAI function name 规则
      expect(tool.name.startsWith('ws__read_file'), isTrue);
      expect(tool.name, matches(RegExp(r'^[a-zA-Z0-9_-]+$')));
      expect(tool.originalName, 'read.file 文件');
      expect(tool.description, '读取文件');
      expect(tool.parameters['type'], 'object');
      expect((tool.parameters['properties'] as Map).containsKey('path'), isTrue);
    });

    test('缺 inputSchema 时给空 schema，缺描述时给默认描述', () {
      final tool = McpTool(client: client, info: {'name': 'ping'});
      expect(tool.parameters, {'type': 'object', 'properties': const {}});
      expect(tool.description.contains('ping'), isTrue);
    });
  });

  group('ToolRegistry', () {
    test('同名工具不会重复注册', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final reg = ToolRegistry(memoryService: MemoryService(db));
      final before = reg.all.length;
      reg.register(_EchoTool('echo_one'));
      reg.register(_EchoTool('echo_one'));
      expect(reg.all.length, before + 1);
    });
  });

  group('McpService CRUD', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });
    tearDown(() async => db.close());

    test('添加、启停、删除服务器', () async {
      final reg = ToolRegistry(memoryService: MemoryService(db));
      final service = McpService(db, reg);

      await service.addServer('文件服务', 'http://192.168.1.10:3000/mcp');
      final servers = await service.listServers();
      expect(servers, hasLength(1));
      expect(servers.single.enabled, isTrue);

      await service.setEnabled(servers.single.id, false);
      expect((await service.listServers()).single.enabled, isFalse);

      await service.removeServer(servers.single.id);
      expect(await service.listServers(), isEmpty);
    });

    test('connectAll：无服务器时返回 0 且不注册工具', () async {
      final reg = ToolRegistry(memoryService: MemoryService(db));
      final service = McpService(db, reg);
      // includeBuiltin: false —— 内置 MCP 是真实网络调用，单测保持无网络依赖
      expect(
          await service.connectAll(
              timeout: const Duration(seconds: 1), includeBuiltin: false),
          0);
      expect(reg.all.any((t) => t.name.startsWith('mcp')), isFalse);
    });
  });
}
