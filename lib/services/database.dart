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

  // ⚠️ 不要把 CREATE INDEX 写在这里。
  // drift 会把 customConstraints 的内容拼进 CREATE TABLE 的括号内
  // （当作列约束，见 migration.dart：
  //   final constraints = dslTable.customConstraints;
  //   for (...) { context.buffer..write(', ')..write(constraints[i]); }
  // ），写成 CREATE INDEX 会得到非法 SQL 导致建表失败，
  // 表现为所有涉及数据库的测试全部报错。
  // 索引统一在 AppDatabase 的 onCreate / onUpgrade 里建，见 _createIndexes。
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
      : super(executor ?? driftDatabase(name: 'orion_agent'));

  @override
  int get schemaVersion => 6;

  /// 全部索引。单独抽出以便 onCreate 与 onUpgrade 共用，避免漏建。
  ///
  /// 不能写在 Table 的 customConstraints 里——drift 会把它们拼进
  /// CREATE TABLE 的括号内（当作列约束），写成 CREATE INDEX 会让建表失败。
  static const _indexStatements = <String>[
    // sessionId 没有索引时，按会话查消息是全表扫描。
    // 复合索引让「按会话取消息并按 id 排序」走索引。
    'CREATE INDEX IF NOT EXISTS idx_message_rows_session '
        'ON message_rows (session_id, id)',
  ];

  Future<void> _createIndexes() async {
    for (final sql in _indexStatements) {
      await customStatement(sql);
    }
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // createAll 只建表，索引要自己建
          await _createIndexes();
        },
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
          // 索引对所有旧版本都要补建（不只是 from < 6）：
          // 之前把它错放在 customConstraints 里，等于从未真正建过索引。
          await _createIndexes();
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
