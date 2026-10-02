import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';

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
  TextColumn get imagesJson => text().withDefault(const Constant('[]'))();
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

/// 知识库文档表。
class KnowledgeDocs extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get chunkCount => integer()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 知识库分块表：embedding 以 float 数组 JSON 存储（v1 暴力余弦检索）。
class KnowledgeChunks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get docId => text()();
  IntColumn get idx => integer()();
  TextColumn get content => text()();
  TextColumn get embeddingJson => text()();
}

/// 快捷指令（技能）：提示词模板，聊天输入 /名称 触发。
class SkillItems extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get template => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Agent 角色（人设）：可切换的 system prompt 附加设定。
class AgentRoles extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get prompt => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// MCP 服务器配置（Streamable HTTP 端点）。
class McpServers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get url => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [
  SessionRows,
  MessageRows,
  MemoryNoteRows,
  KnowledgeDocs,
  KnowledgeChunks,
  SkillItems,
  AgentRoles,
  McpServers,
])
class AppDatabase extends _$AppDatabase {
  /// 生产环境不传 executor；测试注入 NativeDatabase.memory()。
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'pocket_agent'));

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(knowledgeDocs);
            await m.createTable(knowledgeChunks);
          }
          if (from < 3) {
            await m.addColumn(messageRows, messageRows.imagesJson);
          }
          if (from < 4) {
            await m.createTable(skillItems);
            await m.createTable(agentRoles);
          }
          if (from < 5) {
            await m.createTable(mcpServers);
          }
        },
      );
}

// ---------------- 行 ↔ 领域模型映射 ----------------

int _idSeq = 0;

/// 生成唯一 id：时间戳 + 进程内自增序号，避免同毫秒内主键冲突。
String uniqueId(String prefix) =>
    '${prefix}_${DateTime.now().millisecondsSinceEpoch}_${++_idSeq}';

String encodeToolCalls(List<ToolCall> calls) =>
    jsonEncode(calls.map((t) => t.toJson()).toList());

List<ToolCall> decodeToolCalls(String json) => (jsonDecode(json) as List? ?? [])
    .whereType<Map<String, dynamic>>()
    .map(ToolCall.fromJson)
    .toList();

List<String> decodeStringList(String json) =>
    (jsonDecode(json) as List? ?? const []).whereType<String>().toList();

ChatMessage messageFromRow(MessageRow r) => ChatMessage(
      id: r.mid,
      role: r.role,
      content: r.content,
      toolCalls: decodeToolCalls(r.toolCallsJson),
      toolCallId: r.toolCallId,
      toolName: r.toolName,
      images: decodeStringList(r.imagesJson),
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
      imagesJson: Value(jsonEncode(m.images)),
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
