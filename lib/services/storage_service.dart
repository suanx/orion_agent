import 'package:drift/drift.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import 'database.dart';

/// 会话持久化：Drift(SQLite)，按会话/消息粒度写穿保存。
class StorageService {
  StorageService(this._db);

  final AppDatabase _db;

  /// 启动时全量加载（会话按 updatedAt 倒序，消息按插入顺序）。
  ///
  /// 原实现对每个会话单独查一次消息（N+1）。messageRows.sessionId 没有索引，
  /// 于是加载 200 个会话 = 1 + 200 次查询，每次都是 messageRows 全表扫描+排序。
  /// 而 main.dart 在 runApp 之前 await本方法，数据量积累后启动会出现长白屏。
  /// 改为一次性取出全部消息再按 sessionId 分组。
  Future<List<ChatSession>> loadSessions() async {
    final rows = await (_db.select(_db.sessionRows)
          ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]))
        .get();

    final allMsgs = await (_db.select(_db.messageRows)
          ..orderBy([(m) => OrderingTerm.asc(m.id)]))
        .get();
    final bySession = <String, List<ChatMessage>>{};
    for (final m in allMsgs) {
      (bySession[m.sessionId] ??= []).add(messageFromRow(m));
    }

    return [
      for (final s in rows)
        sessionFromRow(s, bySession[s.id] ?? const <ChatMessage>[]),
    ];
  }

  Future<void> insertSession(ChatSession s) =>
      _db.into(_db.sessionRows).insert(sessionToCompanion(s));

  /// 会话元信息（标题、更新时间）写回。
  Future<void> updateSessionMeta(ChatSession s) =>
      (_db.update(_db.sessionRows)..where((x) => x.id.equals(s.id))).write(
        SessionRowsCompanion(
          title: Value(s.title),
          updatedAt: Value(s.updatedAt.millisecondsSinceEpoch),
        ),
      );

  Future<void> insertMessage(String sessionId, ChatMessage m) =>
      _db.into(_db.messageRows).insert(messageToCompanion(sessionId, m));

  /// 整体替换一个会话的消息（上下文自动压缩用：
  /// 旧历史 + 摘要消息 → 摘要消息 + 保留的近期消息）。
  Future<void> replaceMessages(String sessionId, List<ChatMessage> msgs) =>
      _db.transaction(() async {
        await (_db.delete(_db.messageRows)
              ..where((m) => m.sessionId.equals(sessionId)))
            .go();
        for (final m in msgs) {
          await _db
              .into(_db.messageRows)
              .insert(messageToCompanion(sessionId, m));
        }
      });

  Future<void> deleteSession(String id) => _db.transaction(() async {
        await (_db.delete(_db.messageRows)
              ..where((m) => m.sessionId.equals(id)))
            .go();
        await (_db.delete(_db.sessionRows)..where((s) => s.id.equals(id)))
            .go();
      });

  Future<void> clearSessions() => _db.transaction(() async {
        await _db.delete(_db.messageRows).go();
        await _db.delete(_db.sessionRows).go();
      });

  // ---------------- 自动任务 ----------------

  /// 全部任务（按创建时间倒序）。
  Future<List<TaskRow>> loadTasks() => (_db.select(_db.taskRows)
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
      .get();

  Future<void> insertTask(TaskRow row) =>
      _db.into(_db.taskRows).insert(row, mode: InsertMode.replace);

  /// 用整行对象更新（UI 编辑后直接回写，字段少不值得做 Companion 映射）。
  Future<void> updateTask(TaskRow row) =>
      _db.update(_db.taskRows).replace(row);

  Future<void> deleteTask(String id) =>
      (_db.delete(_db.taskRows)..where((t) => t.id.equals(id))).go();

  /// 记录一次任务运行结果。
  Future<void> recordTaskRun(String id,
      {required int lastRunAt, required String status, String? result}) async {
    await (_db.update(_db.taskRows)..where((t) => t.id.equals(id))).write(
      TaskRowsCompanion(
        lastRunAt: Value(lastRunAt),
        lastStatus: Value(status),
        lastResult: Value(result),
      ),
    );
  }
}
