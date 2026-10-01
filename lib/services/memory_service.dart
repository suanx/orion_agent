import 'package:drift/drift.dart';

import '../models/memory_note.dart';
import 'database.dart';

/// 长期记忆服务：Drift(SQLite) 持久化，内存缓存供同步读取。
class MemoryService {
  MemoryService(this._db);

  final AppDatabase _db;

  final List<MemoryNote> _notes = [];
  bool _loaded = false;

  List<MemoryNote> get notes => List.unmodifiable(_notes);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final rows = await (_db.select(_db.memoryNoteRows)
          ..orderBy([(n) => OrderingTerm.asc(n.createdAt)]))
        .get();
    _notes
      ..clear()
      ..addAll(rows
          .map((r) => MemoryNote(
                id: r.id,
                text: r.body,
                createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
              ))
          .toList());
  }

  Future<void> addNote(String text) async {
    await load();
    final note = MemoryNote(
      id: 'mem_${DateTime.now().millisecondsSinceEpoch}',
      text: text,
      createdAt: DateTime.now(),
    );
    await _db.into(_db.memoryNoteRows).insert(
          MemoryNoteRowsCompanion(
            id: Value(note.id),
            body: Value(note.text),
            createdAt: Value(note.createdAt.millisecondsSinceEpoch),
          ),
        );
    _notes.add(note);
  }

  Future<void> removeNote(String id) async {
    await load();
    await (_db.delete(_db.memoryNoteRows)..where((n) => n.id.equals(id))).go();
    _notes.removeWhere((n) => n.id == id);
  }

  /// 注入到 system prompt 的记忆文本。
  String memoryPrompt() {
    if (_notes.isEmpty) return '';
    final lines = _notes.map((n) => '- ${n.text}').join('\n');
    return '\n以下是关于用户的已知长期信息，回答时可自然使用：\n$lines';
  }
}
