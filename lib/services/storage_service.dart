import 'package:drift/drift.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import 'database.dart';

/// 会话持久化：Drift(SQLite)，按会话/消息粒度写穿保存。
class StorageService {
  StorageService(this._db);

  final AppDatabase _db;

  /// 启动时全量加载（会话按 updatedAt 倒序，消息按插入顺序）。
  Future<List<ChatSession>> loadSessions() async {
    final rows = await (_db.select(_db.sessionRows)
          ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]))
        .get();
    final result = <ChatSession>[];
    for (final s in rows) {
      final msgs = await (_db.select(_db.messageRows)
            ..where((m) => m.sessionId.equals(s.id))
            ..orderBy([(m) => OrderingTerm.asc(m.id)]))
          .get();
      result.add(sessionFromRow(s, msgs.map(messageFromRow).toList()));
    }
    return result;
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
