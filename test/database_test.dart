import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/models/chat_message.dart';
import 'package:orion_agent/models/chat_session.dart';
import 'package:orion_agent/services/database.dart';
import 'package:orion_agent/services/memory_service.dart';
import 'package:orion_agent/services/storage_service.dart';

void main() {
  late AppDatabase db;
  late StorageService storage;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageService(db);
  });
  tearDown(() async => db.close());

  ChatSession buildSession() => ChatSession(
        id: 's1',
        title: '新对话',
        messages: [
          ChatMessage(id: 'm1', role: 'user', content: '你好'),
          ChatMessage(
            id: 'm2',
            role: 'assistant',
            content: '你好！',
            toolCalls: [
              const ToolCall(id: 'c1', name: 'calc', arguments: '{"a":1}'),
            ],
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );

  Future<void> seedSession(ChatSession s) async {
    await storage.insertSession(s);
    for (final m in s.messages) {
      await storage.insertMessage(s.id, m);
    }
  }

  test('会话与消息写入后可完整读回（消息按需加载，v0.2.27-beta）', () async {
    final s = buildSession();
    await seedSession(s);
    s.title = '改过的标题';
    await storage.updateSessionMeta(s);

    // 启动路径：列表只含元信息，不带消息（P1）
    final loaded = await storage.loadSessions();
    expect(loaded, hasLength(1));
    final first = loaded.first;
    expect(first.id, 's1');
    expect(first.title, '改过的标题');
    expect(first.messages, isEmpty,
        reason: '列表路径不加载消息，消息进会话时才按需读');

    // 进入会话：按需加载消息（含工具调用）
    final msgs = await storage.loadMessages('s1');
    expect(msgs, hasLength(2));
    expect(msgs[0].content, '你好');
    expect(msgs[1].toolCalls.single.name, 'calc');
  });

  test('消息按插入顺序读回（loadMessages）', () async {
    await seedSession(buildSession());
    final msgs = await storage.loadMessages('s1');
    expect(msgs.map((m) => m.id).toList(), ['m1', 'm2']);
  });

  test('删除会话同时删除其消息', () async {
    await seedSession(buildSession());
    await storage.deleteSession('s1');
    expect(await storage.loadSessions(), isEmpty);
  });

  test('clearSessions 清空全部数据', () async {
    final s = buildSession();
    await seedSession(s);
    await storage.clearSessions();
    expect(await storage.loadSessions(), isEmpty);
  });

  test('长期记忆增删与跨实例读回', () async {
    final memory = MemoryService(db);
    await memory.addNote('用户喜欢简洁回复');
    await memory.addNote('用户时区是 GMT+8');
    expect(memory.notes, hasLength(2));

    final fresh = MemoryService(db);
    await fresh.load();
    expect(fresh.notes.map((n) => n.text).toList(),
        ['用户喜欢简洁回复', '用户时区是 GMT+8']);

    await fresh.removeNote(fresh.notes.first.id);
    expect(fresh.notes, hasLength(1));
  });

  group('decodeToolCalls 容错（坏数据降级为空列表，不炸加载链路）', () {
    test('非 JSON 字符串返回空列表且不抛异常', () {
      expect(decodeToolCalls('not json at all'), isEmpty);
      expect(decodeToolCalls(''), isEmpty);
    });

    test('JSON 非数组（如对象、null 字面量）返回空列表', () {
      expect(decodeToolCalls('{"a":1}'), isEmpty);
      expect(decodeToolCalls('null'), isEmpty);
    });

    test('JSON 数组但元素类型错误被过滤', () {
      // 元素不是 Map：whereType 丢弃，非法字段静默降级
      expect(decodeToolCalls('[1,2,3]'), isEmpty);
      expect(decodeToolCalls('["str"]'), isEmpty);
      // 半条合法数据：合法项保留
      final decoded = decodeToolCalls('[{"id":"c1","name":"calc"},123]');
      expect(decoded, hasLength(1));
      expect(decoded.single.name, 'calc');
    });

    test('合法 toolCalls JSON 正常解码', () {
      final decoded = decodeToolCalls(
          '[{"id":"c1","name":"calc","arguments":"{\\"a\\":1}"}]');
      expect(decoded, hasLength(1));
      expect(decoded.single.id, 'c1');
      expect(decoded.single.name, 'calc');
      expect(decoded.single.arguments, '{"a":1}');
    });
  });

  group('decodeStringList 容错（损坏数据降级为空列表）', () {
    test('非 JSON 字符串返回空列表且不抛异常', () {
      expect(decodeStringList('garbage'), isEmpty);
      expect(decodeStringList(''), isEmpty);
    });

    test('数组内非字符串元素被过滤，字符串保留', () {
      expect(decodeStringList('[1,"a",true,null,"b"]'), ['a', 'b']);
    });

    test('合法字符串数组正常解码', () {
      expect(decodeStringList('["x","y"]'), ['x', 'y']);
    });
  });
}
