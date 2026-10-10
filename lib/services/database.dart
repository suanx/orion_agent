import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

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

  /// 思考过程（模型返回的 reasoning_content / reasoning 累积）。
  /// assistant 消息可有；为 null 表示该模型没输出思考内容。
  TextColumn get reasoning => text().nullable()();

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

/// 单次模型调用的 token 用量。
///
/// OpenAI 兼容协议在每个 SSE 响应的**顶层**返回 usage（不在 choices 里）：
///   {"usage":{"prompt_tokens":N,"completion_tokens":N,
///             "prompt_tokens_details":{"cached_tokens":N}}}
/// `cachedTokens` 是命中提示词缓存的部分，对应界面上的「缓存命中率」。
///
/// 流式响应里 usage 通常在最后一帧才出现，且部分网关还会额外发一个
/// `choices: []` 的空帧专门携带 usage —— 解析时必须两种都覆盖。
class TokenUsageRows extends Table {
  TextColumn get id => text()();
  IntColumn get createdAt => integer()();

  /// 模型服务名（渠道统计维度）。
  TextColumn get provider => text()();
  TextColumn get model => text()();

  /// 输入 / 输出 / 缓存命中 / 请求次数。
  IntColumn get inputTokens => integer()();
  IntColumn get outputTokens => integer()();
  IntColumn get cachedTokens => integer()();
  IntColumn get requests => integer()();

  /// 估算的费用（分）。无价格表时为 0。
  IntColumn get costCents => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 自动任务：定时或手动触发的 Agent 提示词。
///
/// 任务运行结果直接存在行内（lastResult），不进消息表——
/// 任务运行不属于任何会话，单独成表避免把会话列表撑乱。
class TaskRows extends Table {
  TextColumn get id => text()();
  TextColumn get emoji => text().withDefault(const Constant('⏰'))();
  TextColumn get name => text()();
  TextColumn get prompt => text()();

  /// 'manual' = 仅手动运行；'daily' = 每天定时（hour/minute）。
  TextColumn get scheduleType => text().withDefault(const Constant('manual'))();
  IntColumn get scheduleHour => integer().nullable()();
  IntColumn get scheduleMinute => integer().nullable()();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// 最近一次运行的时间戳（毫秒）与状态（ok / fail）。
  IntColumn get lastRunAt => integer().nullable()();
  TextColumn get lastStatus => text().nullable()();

  /// 最近一次运行的 Agent 输出。任务只保留最近一次结果，
  /// 历史结果如需留存以后再单开结果表。
  TextColumn get lastResult => text().nullable()();

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
  TokenUsageRows,
  TaskRows,
])
class AppDatabase extends _$AppDatabase {
  /// 生产环境不传 executor；测试注入 NativeDatabase.memory()。
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'orion_agent'));

  @override
  int get schemaVersion => 10;

  /// 全部索引。单独抽出以便 onCreate 与 onUpgrade 共用，避免漏建。
  ///
  /// 不能写在 Table 的 customConstraints 里——drift 会把它们拼进
  /// CREATE TABLE 的括号内（当作列约束），写成 CREATE INDEX 会让建表失败。
  static const _indexStatements = <String>[
    // sessionId 没有索引时，按会话查消息是全表扫描。
    // 复合索引让「按会话取消息并按 id 排序」走索引。
    'CREATE INDEX IF NOT EXISTS idx_message_rows_session '
        'ON message_rows (session_id, id)',
    // Token 统计页按时间倒序取用量，没有索引会全表扫描。
    'CREATE INDEX IF NOT EXISTS idx_token_usage_created '
        'ON token_usage_rows (created_at)',
    // 知识库文档删除/分块清理按 docId 过滤（2026-10-11 P2）：
    // DELETE FROM knowledge_chunks WHERE doc_id = ? 没有索引是全表扫描。
    'CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_doc '
        'ON knowledge_chunks (doc_id)',
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
          if (from < 7) {
            await m.createTable(tokenUsageRows);
          }
          if (from < 8) {
            // 思考过程列：历史消息没有思考内容，加可空列即可。
            await m.addColumn(messageRows, messageRows.reasoning);
          }
          if (from < 9) {
            await m.createTable(taskRows);
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

/// 解码 toolCalls JSON。单行数据损坏（半行写入/手动改库）不应炸掉
/// 整个会话加载链路——返回空列表并留痕，让坏行静默降级。
List<ToolCall> decodeToolCalls(String json) {
  try {
    return (jsonDecode(json) as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ToolCall.fromJson)
        .toList();
  } catch (e) {
    debugPrint('decodeToolCalls 容错：非法数据已降级为空列表 '
        '(${e.toString().split('\n').first})');
    return const [];
  }
}

/// 同 [decodeToolCalls]：损坏数据降级为空列表。
List<String> decodeStringList(String json) {
  try {
    return (jsonDecode(json) as List? ?? const [])
        .whereType<String>()
        .toList();
  } catch (e) {
    debugPrint('decodeStringList 容错：非法数据已降级为空列表 '
        '(${e.toString().split('\n').first})');
    return const [];
  }
}

ChatMessage messageFromRow(MessageRow r) => ChatMessage(
      id: r.mid,
      role: r.role,
      content: r.content,
      toolCalls: decodeToolCalls(r.toolCallsJson),
      toolCallId: r.toolCallId,
      toolName: r.toolName,
      images: decodeStringList(r.imagesJson),
      reasoning: r.reasoning,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
    );

MessageRowsCompanion messageToCompanion(String sessionId, ChatMessage m,
        {List<String>? imageRefs}) =>
    MessageRowsCompanion(
      mid: Value(m.id),
      sessionId: Value(sessionId),
      role: Value(m.role),
      content: Value(m.content),
      toolCallsJson: Value(encodeToolCalls(m.toolCalls)),
      toolCallId: Value(m.toolCallId),
      toolName: Value(m.toolName),
      // imageRefs：落盘后的文件引用列表（P2，v0.2.27-beta）；null 时
      // 原样存 data URL（兼容备份导入等未经落盘的调用方）
      imagesJson: Value(jsonEncode(imageRefs ?? m.images)),
      reasoning: Value(m.reasoning),
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
