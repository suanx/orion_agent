import 'package:drift/drift.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import 'database.dart';
import 'message_image_store.dart';

/// 会话持久化：Drift(SQLite)，按会话/消息粒度写穿保存。
class StorageService {
  StorageService(this._db);

  final AppDatabase _db;

  /// 启动加载：**只取会话元信息，不加载消息**（评估项 P1，v0.2.27-beta）。
  ///
  /// 消息改为进入会话时按需加载（[loadMessages]）。此前启动把所有会话的
  /// 全部消息（含图片 JSON）一次性载入内存，数据量积累后启动时间与内存
  /// 随历史线性增长——这是长期使用的头号瓶颈。
  Future<List<ChatSession>> loadSessions() async {
    final rows = await (_db.select(_db.sessionRows)
          ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]))
        .get();
    return [
      for (final s in rows) sessionFromRow(s, const []),
    ];
  }

  /// 按需加载单个会话的消息（进入会话时调用，图片从落盘文件还原）。
  Future<List<ChatMessage>> loadMessages(String sessionId) async {
    final rows = await (_db.select(_db.messageRows)
          ..where((m) => m.sessionId.equals(sessionId))
          ..orderBy([(m) => OrderingTerm.asc(m.id)]))
        .get();
    final msgs = <ChatMessage>[];
    for (final r in rows) {
      final base = messageFromRow(r);
      if (base.images.isEmpty) {
        msgs.add(base);
        continue;
      }
      // 图片落盘后 DB 里存的是文件引用，这里还原成 data URL 供 UI 使用
      msgs.add(ChatMessage(
        id: base.id,
        role: base.role,
        content: base.content,
        toolCalls: base.toolCalls,
        toolCallId: base.toolCallId,
        toolName: base.toolName,
        images: await MessageImageStore.instance.resolve(base.images),
        reasoning: base.reasoning,
        createdAt: base.createdAt,
      ));
    }
    return msgs;
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

  Future<void> insertMessage(String sessionId, ChatMessage m) async {
    // 图片先落盘，DB 里只存文件引用（P2）。失败时 store 内部降级为
    // 原样存 data URL，不影响消息本身落库。
    final refs = await MessageImageStore.instance.store(m.id, m.images);
    await _db
        .into(_db.messageRows)
        .insert(messageToCompanion(sessionId, m, imageRefs: refs));
  }

  /// 整体替换一个会话的消息（上下文自动压缩用：
  /// 旧历史 + 摘要消息 → 摘要消息 + 保留的近期消息）。
  Future<void> replaceMessages(String sessionId, List<ChatMessage> msgs) =>
      _db.transaction(() async {
        // 压缩会把旧消息行删掉，其落盘图片必须一并回收（2026-10-11 P1）：
        // 先收集被移除消息的图片引用，删行后清理文件。存留消息（含摘要）
        // 的引用不动。
        final kept = {for (final m in msgs) m.id};
        final oldRows = await (_db.select(_db.messageRows)
              ..where((m) => m.sessionId.equals(sessionId)))
            .get();
        final orphanRefs = <String>[
          for (final r in oldRows)
            if (!kept.contains(r.mid))
              ...MessageImageStore.refsFromJson(r.imagesJson),
        ];
        await (_db.delete(_db.messageRows)
              ..where((m) => m.sessionId.equals(sessionId)))
            .go();
        for (final m in msgs) {
          final refs =
              await MessageImageStore.instance.store(m.id, m.images);
          await _db
              .into(_db.messageRows)
              .insert(messageToCompanion(sessionId, m, imageRefs: refs));
        }
        if (orphanRefs.isNotEmpty) {
          await MessageImageStore.instance.deleteRefs(orphanRefs);
        }
      });

  Future<void> deleteSession(String id) => _db.transaction(() async {
        // 删会话前先收集该会话全部图片引用，删行后回收落盘文件
        // （2026-10-11 P1：此前只删 DB 行，img/ 只增不减）。
        final rows = await (_db.select(_db.messageRows)
              ..where((m) => m.sessionId.equals(id)))
            .get();
        final refs = <String>[
          for (final r in rows) ...MessageImageStore.refsFromJson(r.imagesJson),
        ];
        await (_db.delete(_db.messageRows)
              ..where((m) => m.sessionId.equals(id)))
            .go();
        await (_db.delete(_db.sessionRows)..where((s) => s.id.equals(id)))
            .go();
        if (refs.isNotEmpty) {
          await MessageImageStore.instance.deleteRefs(refs);
        }
      });

  Future<void> clearSessions() => _db.transaction(() async {
        await _db.delete(_db.messageRows).go();
        await _db.delete(_db.sessionRows).go();
        // 全部会话都没了，落盘图片整目录回收。
        await MessageImageStore.instance.deleteAll();
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
