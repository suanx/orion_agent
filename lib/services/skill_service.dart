import 'package:drift/drift.dart';

import 'database.dart';

/// 快捷指令服务：提示词模板的增删查，内存缓存供同步读取。
/// 聊天输入「/名称 参数」触发；模板中的 {input} 会被参数替换。
class SkillService {
  SkillService(this._db);

  final AppDatabase _db;

  final List<SkillItem> _cache = [];
  bool _loaded = false;

  List<SkillItem> get skills => List.unmodifiable(_cache);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final rows = await (_db.select(_db.skillItems)
          ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
        .get();
    _cache
      ..clear()
      ..addAll(rows);
  }

  Future<void> addSkill(String name, String template) async {
    await load();
    final row = SkillItem(
      id: uniqueId('skill'),
      name: name,
      template: template,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.into(_db.skillItems).insert(SkillItemsCompanion(
          id: Value(row.id),
          name: Value(row.name),
          template: Value(row.template),
          createdAt: Value(row.createdAt),
        ));
    _cache.insert(0, row);
  }

  Future<void> removeSkill(String id) async {
    await load();
    await (_db.delete(_db.skillItems)..where((s) => s.id.equals(id))).go();
    _cache.removeWhere((s) => s.id == id);
  }

  SkillItem? findByName(String name) {
    for (final s in _cache) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 把「/名称 参数」展开成完整提示词；无参数时直接返回模板。
  static String expand(SkillItem skill, String args) {
    final trimmed = args.trim();
    if (skill.template.contains('{input}')) {
      return skill.template.replaceAll('{input}', trimmed);
    }
    return trimmed.isEmpty
        ? skill.template
        : '${skill.template}\n\n补充输入：$trimmed';
  }
}
