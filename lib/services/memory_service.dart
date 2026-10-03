import 'package:characters/characters.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../models/memory_note.dart';
import 'database.dart';

/// 长期记忆服务：Drift(SQLite) 持久化，内存缓存供同步读取。
class MemoryService {
  MemoryService(this._db);

  /// 最多持久化/保留的条数（超出淘汰最旧的）。
  static const _maxStored = 200;
  /// 注入 prompt 的上限：最多 60 条、每条 200 字，约 12k 字符以内。
  static const _maxNotes = 60;
  static const _maxCharsPerNote = 200;

  final AppDatabase _db;

  final List<MemoryNote> _notes = [];
  // _loaded 只在查询【成功后】置位。
  // 原实现 await 之前就置位：查询失败后 _loaded 仍为 true 而 _notes 为空，
  // 长期记忆从此永久失效（只能重启 App），且异常被完全吞掉。
  bool _loaded = false;
  // 并发加载共享同一个 Future，避免并发调用方看到空列表。
  // 注意不能只靠 _loaded 去重：首次加载期间并发调用必须等同一个结果，
  // 否则 addNote 会拿到空 _notes 就开始去重/插入。
  Future<void>? _loading;

  List<MemoryNote> get notes => List.unmodifiable(_notes);

  Future<void> load() async {
    if (_loaded) return;
    final pending = _loading;
    if (pending != null) return pending;
    final fut = _doLoad();
    _loading = fut;
    try {
      await fut;
      // 只在成功路径置位，失败后允许重试
      _loaded = true;
    } finally {
      _loading = null;
    }
  }

  Future<void> _doLoad() async {
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
    final body = text.trim();
    // 去重：Agent 在 ReAct 循环里可能对同一件事反复 save_memory，
    // 不去重会让记忆库和prompt 一起膨胀。
    if (_notes.any((n) => n.text.trim() == body)) {
      debugPrint('memory: 跳过重复记忆「$body」');
      return;
    }
    final note = MemoryNote(
      id: uniqueId('mem'),
      text: body,
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
    // 超出保留上限时淘汰最旧的，避免数据库与内存无界增长。
    // 注意必须在 insert 之后删，否则新记录可能被当成最旧的删掉。
    while (_notes.length > _maxStored) {
      final dropped = _notes.removeAt(0);
      await (_db.delete(_db.memoryNoteRows)..where((n) => n.id.equals(dropped.id))).go();
    }
  }

  Future<void> removeNote(String id) async {
    await load();
    await (_db.delete(_db.memoryNoteRows)..where((n) => n.id.equals(id))).go();
    _notes.removeWhere((n) => n.id == id);
  }

  /// 注入到 system prompt 的记忆文本。
  ///
  /// 必须有上限：save_memory 每调用一次就永久追加一条，既无条数上限也无单条长度上限。
  /// 长期使用（尤其 Agent 在 ReAct 循环里反复保存同一件事）会让 system prompt
  /// 无界膨胀，最终触发 API 的 context length 限制，或把模型注意力稀释到失效。
  /// 同一产品的 RAG 侧已有 _defaultTopK / _minScore 做边界控制，这里保持一致。
  String memoryPrompt() {
    if (_notes.isEmpty) return '';
    final recent = _notes.length > _maxNotes
        ? _notes.sublist(_notes.length - _maxNotes)
        : _notes;
    final buf = StringBuffer();
    for (final n in recent) {
      final t = n.text.characters.length > _maxCharsPerNote
          ? '${n.text.characters.take(_maxCharsPerNote).toString()}…'
          : n.text;
      buf.writeln('- $t');
    }
    return '\n以下是关于用户的已知长期信息，回答时可自然使用：\n${buf.toString().trimRight()}';
  }
}
