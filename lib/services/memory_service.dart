import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/memory_note.dart';

/// 长期记忆服务：JSON 文件持久化。
class MemoryService {
  static const _fileName = 'memory_notes.json';

  final List<MemoryNote> _notes = [];
  bool _loaded = false;

  List<MemoryNote> get notes => List.unmodifiable(_notes);

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _notes
          ..clear()
          ..addAll(
              decoded.whereType<Map<String, dynamic>>().map(MemoryNote.fromJson));
      }
    } catch (_) {
      // 记忆文件损坏时静默重建
    }
  }

  Future<void> _save() async {
    final file = await _file();
    await file.writeAsString(jsonEncode(_notes.map((n) => n.toJson()).toList()));
  }

  Future<void> addNote(String text) async {
    await load();
    _notes.add(MemoryNote(
      id: 'mem_${DateTime.now().millisecondsSinceEpoch}',
      text: text,
      createdAt: DateTime.now(),
    ));
    await _save();
  }

  Future<void> removeNote(String id) async {
    await load();
    _notes.removeWhere((n) => n.id == id);
    await _save();
  }

  /// 注入到 system prompt 的记忆文本。
  String memoryPrompt() {
    if (_notes.isEmpty) return '';
    final lines = _notes.map((n) => '- ${n.text}').join('\n');
    return '\n以下是关于用户的已知长期信息，回答时可自然使用：\n$lines';
  }
}
