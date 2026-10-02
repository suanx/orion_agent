import 'package:drift/drift.dart';

import 'database.dart';

/// Agent 角色服务：人设（附加 system prompt）的增删查，内存缓存。
class RoleService {
  RoleService(this._db);

  final AppDatabase _db;

  final List<AgentRole> _cache = [];
  bool _loaded = false;

  List<AgentRole> get roles => List.unmodifiable(_cache);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final rows = await (_db.select(_db.agentRoles)
          ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]))
        .get();
    _cache
      ..clear()
      ..addAll(rows);
  }

  Future<void> addRole(String name, String prompt) async {
    await load();
    final row = AgentRole(
      id: uniqueId('role'),
      name: name,
      prompt: prompt,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.into(_db.agentRoles).insert(AgentRolesCompanion(
          id: Value(row.id),
          name: Value(row.name),
          prompt: Value(row.prompt),
          createdAt: Value(row.createdAt),
        ));
    _cache.insert(0, row);
  }

  Future<void> updateRole(String id, String name, String prompt) async {
    await load();
    await (_db.update(_db.agentRoles)..where((r) => r.id.equals(id))).write(
      AgentRolesCompanion(name: Value(name), prompt: Value(prompt)),
    );
    final idx = _cache.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      _cache[idx] = AgentRole(
        id: id,
        name: name,
        prompt: prompt,
        createdAt: _cache[idx].createdAt,
      );
    }
  }

  Future<void> removeRole(String id) async {
    await load();
    await (_db.delete(_db.agentRoles)..where((r) => r.id.equals(id))).go();
    _cache.removeWhere((r) => r.id == id);
  }

  String? promptOf(String id) {
    for (final r in _cache) {
      if (r.id == id) return r.prompt;
    }
    return null;
  }
}
