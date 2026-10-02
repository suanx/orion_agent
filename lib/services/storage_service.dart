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
}
