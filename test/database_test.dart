import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/models/chat_message.dart';
import 'package:pocket_agent/models/chat_session.dart';
import 'package:pocket_agent/services/database.dart';
import 'package:pocket_agent/services/memory_service.dart';
import 'package:pocket_agent/services/storage_service.dart';

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

  test('会话与消息写入后可完整读回', () async {
    final s = buildSession();
    await seedSession(s);
    s.title = '改过的标题';
    await storage.updateSessionMeta(s);

    final loaded = await storage.loadSessions();
    expect(loaded, hasLength(1));
    final first = loaded.first;
    expect(first.id, 's1');
    expect(first.title, '改过的标题');
    expect(first.messages, hasLength(2));
    expect(first.messages[0].content, '你好');
    expect(first.messages[1].toolCalls.single.name, 'calc');
  });

  test('消息按插入顺序读回', () async {
    await seedSession(buildSession());
    final loaded = await storage.loadSessions();
    expect(loaded.first.messages.map((m) => m.id).toList(), ['m1', 'm2']);
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
}
