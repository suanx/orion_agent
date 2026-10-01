import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/memory_note.dart';

part 'database.g.dart';

/// 会话表（消息单独存表，避免整会话重写）。
class SessionRows extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 消息表。自增 id 即插入顺序，会话内消息按它排序。
class MessageRows extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get mid => text()();
  TextColumn get sessionId => text()();
  TextColumn get role => text()();
  TextColumn get content => text()();
  TextColumn get toolCallsJson => text().withDefault(const Constant('[]'))();
  TextColumn get toolCallId => text().nullable()();
  TextColumn get toolName => text().nullable()();
  IntColumn get createdAt => integer()();
}

/// 长期记忆表。
class MemoryNoteRows extends Table {
  TextColumn get id => text()();
  TextColumn get body => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [SessionRows, MessageRows, MemoryNoteRows])
class AppDatabase extends _$AppDatabase {
  /// 生产环境不传 executor；测试注入 NativeDatabase.memory()。
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'pocket_agent'));

  @override
  int get schemaVersion => 1;
}

// ---------------- 行 ↔ 领域模型映射 ----------------

String encodeToolCalls(List<ToolCall> calls) =>
    jsonEncode(calls.map((t) => t.toJson()).toList());

List<ToolCall> decodeToolCalls(String json) => (jsonDecode(json) as List? ?? [])
    .whereType<Map<String, dynamic>>()
    .map(ToolCall.fromJson)
    .toList();

ChatMessage messageFromRow(MessageRow r) => ChatMessage(
      id: r.mid,
      role: r.role,
      content: r.content,
      toolCalls: decodeToolCalls(r.toolCallsJson),
      toolCallId: r.toolCallId,
      toolName: r.toolName,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
    );

MessageRowsCompanion messageToCompanion(String sessionId, ChatMessage m) =>
    MessageRowsCompanion(
      mid: Value(m.id),
      sessionId: Value(sessionId),
      role: Value(m.role),
      content: Value(m.content),
      toolCallsJson: Value(encodeToolCalls(m.toolCalls)),
      toolCallId: Value(m.toolCallId),
      toolName: Value(m.toolName),
      createdAt: Value(m.createdAt.millisecondsSinceEpoch),
    );

ChatSession sessionFromRow(SessionRow r, List<ChatMessage> messages) =>
    ChatSession(
      id: r.id,
      title: r.title,
      messages: messages,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r.updatedAt),
    );

SessionRowsCompanion sessionToCompanion(ChatSession s) =>
    SessionRowsCompanion(
      id: Value(s.id),
      title: Value(s.title),
      createdAt: Value(s.createdAt.millisecondsSinceEpoch),
      updatedAt: Value(s.updatedAt.millisecondsSinceEpoch),
    );
