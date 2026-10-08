import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_service.dart';
import 'cloud_sync_crypto.dart';
import 'cloud_service.dart';
import 'database.dart';
import 'message_image_store.dart';

/// 云端备份 + 多端同步（端上加密，服务端零知识）。
///
/// 加密：密钥 = PBKDF2-HMAC-SHA256(账号密码, 固定盐, 2万次) → AES-256-GCM。
/// 同一账号在任何设备用同一密码登录，派生出同一把密钥，因此可以互相解密；
/// 服务端只拿到密文与元数据（表名/行 ID/时间戳/设备），读不到任何内容。
/// 密钥派生一次后存进系统安全存储（Android Keystore），**不保存密码本身**。
///
/// 同步粒度（兼顾增量与合并安全，行的体量可控）：
/// - `prefs`    单行：AI 供应商配置 + MCP 服务器 + 应用设置（末写胜出）
/// - `sessions` 每会话一行：会话元信息
/// - `messages` 每会话一行：该会话的消息数组（按 mid 合并，不整库覆盖）
///
/// 删除传播：端上删除会话时记入待删队列，同步时以 tombstone 上传，
/// 其它设备拉到后删掉同一会话。
class CloudSyncService {
  CloudSyncService(this._cloud, this._db, this._prefs, this._secure,
      {required this.backup});

  /// 派生密钥存安全存储时的键前缀（按账号分设备条目）。
  static const _keyStoragePrefix = 'cloud_sync_key_';
  static const _prefsRowId = 'default';
  static const _keyCheckRowId = '__keycheck__';

  /// 同步涉及的表（也用于云备份快照）。
  static const syncTables = <String>['prefs', 'sessions', 'messages'];

  final CloudService _cloud;
  final AppDatabase _db;
  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  final BackupService backup;

  Uint8List? _keyCache;
  String? _keyAccount;

  // ---------------- 开关与状态 ----------------

  bool get isEnabled => _prefs.getBool(_flagEnabled) ?? false;

  Future<void> setEnabled(bool on) async {
    await _prefs.setBool(_flagEnabled, on);
    if (!on) {
      // 关闭时忘掉派生密钥（下次开启需重新输入密码）
      _keyCache = null;
      _keyAccount = null;
      final email = _cloud.email;
      if (email != null) await _secure.delete(key: '$_keyStoragePrefix$email');
    }
  }

  static const _flagEnabled = 'cloud_sync_enabled';
  static const _flagLastSync = 'cloud_sync_last_at';
  static const _flagPushed = 'cloud_sync_pushed_'; // row 指纹前缀
  static const _flagDeleted = 'cloud_sync_deleted_sessions';

  DateTime? get lastSyncAt {
    final ms = _prefs.getInt(_flagLastSync);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  bool get isUnlocked => _keyCache != null;

  /// 派生并缓存密钥；同时用云端已有数据验证密码是否正确。
  /// 密码错（服务端数据是用旧密码加密的）抛 [CloudSyncPasswordWrong]。
  Future<void> unlock(String password) async {
    final email = _cloud.email;
    if (email == null || email.isEmpty) {
      throw const CloudSyncException('请先登录云端账号');
    }
    // 已缓存且同账号 → 复用，避免每次都做 KDF（10 万次迭代不便宜）
    if (_keyCache != null && _keyAccount == email) return;

    // 优先复用安全存储里的密钥（同设备再次开启无需重输密码）
    final saved = await _secure.read(key: '$_keyStoragePrefix$email');
    if (saved != null && saved.isNotEmpty) {
      _keyCache = base64Decode(saved);
      _keyAccount = email;
      return;
    }

    final key = CloudSyncCrypto.deriveKey(password);
    // 验证：云端已有数据时必须能解出，否则说明密码不对
    final probe = await _cloud.authedGet('/api/sync/pull?since=0&limit=1');
    final rows = (probe['rows'] as List?) ?? const [];
    if (rows.isNotEmpty) {
      final row = rows.first as Map<String, dynamic>;
      try {
        CloudSyncCrypto.decryptJson(key, row['payload'] as String,
            row['nonce'] as String? ?? '');
      } on CloudSyncCryptoError {
        throw const CloudSyncPasswordWrong();
      }
    }
    _keyCache = key;
    _keyAccount = email;
    await _secure.write(key: '$_keyStoragePrefix$email', value: base64Encode(key));
    // 首次解锁写入校验行，供换设备时验证密码
    final check = CloudSyncCrypto.encryptJson(
        key, {'v': 1, 'at': DateTime.now().toIso8601String()});
    await _pushRows('prefs', [
      {
        'table': 'prefs',
        'rowId': _keyCheckRowId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'payload': check.payload,
        'nonce': check.nonce,
      }
    ]);
  }

  /// 锁定（清除内存中的密钥）
  void lock() {
    _keyCache = null;
    _keyAccount = null;
  }

  Uint8List get _key {
    final k = _keyCache;
    if (k == null) {
      throw const CloudSyncException('云同步未解锁，请先输入账号密码');
    }
    return Uint8List.fromList(k);
  }

  _CipherText _encryptJson(Object data) {
    final c = CloudSyncCrypto.encryptJson(_key, data);
    return _CipherText(c.payload, c.nonce);
  }

  Object _decryptJson(String payloadB64, String nonceB64) {
    try {
      return CloudSyncCrypto.decryptJson(_key, payloadB64, nonceB64);
    } on CloudSyncCryptoError {
      throw const CloudSyncPasswordWrong();
    }
  }

  // ---------------- 云备份（整表快照）----------------

  /// 上传整表快照到云端（覆盖同表旧快照）。
  Future<void> uploadSnapshot(String table) async {
    final data = await _buildTablePayload(table);
    final cipher = _encryptJson(data);
    await _cloud.authedPut('/api/backup/$table', {
      'payload': cipher.payload,
      'nonce': cipher.nonce,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 上传全部快照（prefs / sessions / messages）。
  Future<void> uploadAll() async {
    for (final t in syncTables) {
      await uploadSnapshot(t);
    }
  }

  /// 从云端取回某表快照并恢复（合并语义）。
  Future<List<String>> restoreTable(String table) async {
    final resp = await _cloud.authedGet('/api/backup/$table');
    final data = _decryptJson(resp['payload'] as String, resp['nonce'] as String? ?? '');
    return _applyTable(table, data);
  }

  /// 云端占用统计。
  Future<({int bytes, int limit})> cloudUsage() async {
    final r = await _cloud.authedGet('/api/backup/usage');
    return (
      bytes: (r['bytes'] as num?)?.toInt() ?? 0,
      limit: (r['limit'] as num?)?.toInt() ?? 0,
    );
  }

  /// 删除云端全部备份快照。
  Future<void> deleteCloudBackups() => _cloud.authedDelete('/api/backup');

  /// 清空云端同步数据（各表逐个清），配合 deleteCloudBackups 做彻底重置。
  Future<void> deleteAllCloudSyncData() async {
    for (final t in syncTables) {
      await _cloud.authedDelete('/api/sync/rows?table=$t');
    }
  }

  // ---------------- 多端同步 ----------------

  /// 完整同步一轮：先拉（合并远端），再推（本机变更）。
  Future<SyncSummary> syncNow() async {
    if (!isUnlocked) {
      throw const CloudSyncException('请先解锁云同步');
    }
    final pulled = await _pullAndMerge();
    final pushed = await _pushLocalChanges();
    await _prefs.setInt(_flagLastSync, DateTime.now().millisecondsSinceEpoch);
    return SyncSummary(
      pulledSessions: pulled.sessions,
      pulledMessages: pulled.messages,
      pulledPrefs: pulled.prefs,
      pushedRows: pushed,
      deleted: pulled.deleted,
    );
  }

  /// 记录一个待删除的会话（供下次同步上传 tombstone）。
  Future<void> markSessionDeleted(String sessionId) async {
    final list = _prefs.getStringList(_flagDeleted) ?? <String>[];
    if (!list.contains(sessionId)) list.add(sessionId);
    await _prefs.setStringList(_flagDeleted, list);
  }

  /// 分页拉取全部变更。
  ///
  /// 服务端按 updated_at 升序返回，单页上限 500；用本页最大 updated_at 作为
  /// 下一页的 since 继续拉，直到返回行数小于 limit —— 否则会话多时会被
  /// 静默截断（看起来"同步成功"但实际漏数据）。
  Future<List<Map<String, dynamic>>> _pullAllRows() async {
    const pageSize = 500;
    final all = <Map<String, dynamic>>[];
    var since = 0;
    for (var page = 0; page < 40; page++) {
      // 同一毫秒内的多行不会被漏掉：服务端用 updated_at > since 严格大于，
      // 因此这里以「本页最大 updated_at - 1」作为下一页起点，保证重叠一行，
      // 重复行在合并时按 id/时间戳幂等处理。
      final resp = await _cloud.authedGet('/api/sync/pull?since=$since'
          '&tables=prefs,sessions,messages&limit=$pageSize');
      final rows = ((resp['rows'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      if (rows.isEmpty) break;
      all.addAll(rows);
      if (rows.length < pageSize) break;
      var maxAt = since;
      for (final r in rows) {
        final at = (r['updatedAt'] as num?)?.toInt() ?? 0;
        if (at > maxAt) maxAt = at;
      }
      if (maxAt <= since) break; // 全部同一时间戳, 再拉也是同一批, 防死循环
      since = maxAt - 1;
    }
    return all;
  }

  Future<({int sessions, int messages, int prefs, int deleted})> _pullAndMerge() async {
    final rows = await _pullAllRows();
    var sCount = 0;
    var mCount = 0;
    var pCount = 0;
    var dCount = 0;

    // 远端删除 → 本地删除
    final remoteDeletes = <String>[];
    // 远端会话/消息
    final remoteSessions = <Map<String, dynamic>>[];
    final remoteMessages = <Map<String, dynamic>>[];
    Map<String, dynamic>? remotePrefs;
    Map<String, dynamic>? remotePrefsRow;

    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      final rowId = row['rowId'] as String? ?? '';
      final table = row['table'] as String? ?? '';
      if (rowId == _keyCheckRowId) continue; // 校验行不参与合并
      if (row['tombstone'] == true) {
        if (table == 'sessions' || table == 'messages') remoteDeletes.add(rowId);
        continue;
      }
      final payload = row['payload'] as String? ?? '';
      if (payload.isEmpty) continue;
      final data = _decryptJson(payload, row['nonce'] as String? ?? '');
      if (table == 'sessions' && data is Map) {
        remoteSessions.add(data.cast<String, dynamic>());
      } else if (table == 'messages' && data is List) {
        remoteMessages.add({
          'sessionId': rowId,
          'items': data,
        });
      } else if (table == 'prefs' && data is Map) {
        remotePrefs = data.cast<String, dynamic>();
        remotePrefsRow = row;
      }
    }

    // 1) 远端删除的会话：本地一并删除
    for (final sid in remoteDeletes.toSet()) {
      final n = await _deleteSessionLocal(sid);
      if (n > 0) dCount += n;
    }

    // 2) 会话合并（远端 updatedAt 更新则覆盖标题/时间）
    for (final s in remoteSessions) {
      if (await _mergeSession(s)) sCount++;
    }

    // 3) 消息合并（按 mid 去重，只补本地没有的）
    for (final group in remoteMessages) {
      final sid = group['sessionId'] as String;
      final items = (group['items'] as List).cast<Map>();
      mCount += await _mergeMessages(sid, items);
    }

    // 4) 配置/设置：远端更新则整域恢复（走 BackupService 已验证的导入路径）
    if (remotePrefs != null && remotePrefsRow != null) {
      final at = (remotePrefsRow!['updatedAt'] as num?)?.toInt() ?? 0;
      final localAt = _prefs.getInt(_prefsPushedAtKey) ?? 0;
      if (at > localAt) {
        final backupJson = jsonEncode({
          'app': 'orion_agent',
          'backupVersion': BackupService.currentVersion,
          if (remotePrefs.containsKey('configs'))
            'configs': remotePrefs['configs'],
          if (remotePrefs.containsKey('mcpServers'))
            'mcpServers': remotePrefs['mcpServers'],
          if (remotePrefs.containsKey('settings'))
            'settings': remotePrefs['settings'],
        });
        await backup.restore(backupJson);
        pCount++;
      }
    }
    return (
      sessions: sCount,
      messages: mCount,
      prefs: pCount,
      deleted: dCount,
    );
  }

  /// 推送本机变更：只推指纹变化的行 + 待删会话的 tombstone。
  Future<int> _pushLocalChanges() async {
    var pushed = 0;
    for (final table in syncTables) {
      final rows = await _buildSyncRows(table);
      final changed = <Map<String, dynamic>>[];
      for (final row in rows) {
        final fp = row['_fingerprint'] as String;
        final key = '$_flagPushed$table:${row['rowId']}';
        if (_prefs.getString(key) == fp) continue;
        changed.add(row);
      }
      if (changed.isEmpty) continue;
      final res = await _pushRows(table, changed);
      pushed += res;
      for (final row in changed) {
        await _prefs.setString(
            '$_flagPushed${row['table']}:${row['rowId']}',
            row['_fingerprint'] as String);
      }
    }

    // 待删会话 → tombstone（sessions + messages 两侧都发，收端统一按会话删）
    final pending = _prefs.getStringList(_flagDeleted) ?? <String>[];
    if (pending.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final tombs = [
        for (final sid in pending)
          for (final t in const ['sessions', 'messages'])
            {
              'table': t,
              'rowId': sid,
              'updatedAt': now,
              'tombstone': true,
            }
      ];
      await _pushRows('sessions', tombs);
      await _prefs.remove(_flagDeleted);
      pushed += tombs.length;
      // 本地指纹也清掉，避免重新创建同名会话被误判未推送
      for (final sid in pending) {
        for (final t in const ['sessions', 'messages']) {
          await _prefs.remove('$_flagPushed$t:$sid');
        }
      }
    }
    return pushed;
  }

  Future<int> _pushRows(String _table, List<Map<String, dynamic>> rows) async {
    final resp = await _cloud.authedPost('/api/sync/push', {'rows': rows});
    return (resp['accepted'] as num?)?.toInt() ?? 0;
  }

  // ---------------- 本机数据 → 行 ----------------

  Future<Map<String, dynamic>> _buildTablePayload(String table) async {
    switch (table) {
      case 'prefs':
        return _buildPrefs();
      case 'sessions':
        return {'sessions': await _db.select(_db.sessionRows).get()
            .then((rows) => [
                  for (final s in rows)
                    {
                      'id': s.id,
                      'title': s.title,
                      'createdAt': s.createdAt,
                      'updatedAt': s.updatedAt,
                    }
                ])};
      case 'messages':
        final all = await _db.select(_db.messageRows).get();
        return {
          'messages': [
            for (final m in all)
              {
                'mid': m.mid,
                'sessionId': m.sessionId,
                'role': m.role,
                'content': m.content,
                'toolCallsJson': m.toolCallsJson,
                'toolCallId': m.toolCallId,
                'toolName': m.toolName,
                'imagesJson': jsonEncode(
                    await MessageImageStore.instance.resolveJson(m.imagesJson)),
                'reasoning': m.reasoning,
                'createdAt': m.createdAt,
              }
          ]
        };
      default:
        throw CloudSyncException('未知表：$table');
    }
  }

  Future<Map<String, dynamic>> _buildPrefs() async {
    return {
      'configs': jsonDecode(await _secure.read(key: 'llm_configs') ?? '[]'),
      'mcpServers': [
        for (final r in await _db.select(_db.mcpServers).get())
          {
            'id': r.id,
            'name': r.name,
            'url': r.url,
            'enabled': r.enabled,
            'createdAt': r.createdAt,
          }
      ],
      'settings': {for (final k in _prefs.getKeys()) k: _prefs.get(k)},
    };
  }

  static const _prefsPushedAtKey = 'cloud_sync_prefs_updated_at';

  /// 把本机数据拆成同步行（带指纹，指纹=内容 SHA256 前 16 字节 hex）。
  Future<List<Map<String, dynamic>>> _buildSyncRows(String table) async {
    final rows = <Map<String, dynamic>>[];
    switch (table) {
      case 'prefs':
        final data = await _buildPrefs();
        final cipher = _encryptJson(data);
        final at = DateTime.now().millisecondsSinceEpoch;
        await _prefs.setInt(_prefsPushedAtKey, at);
        rows.add({
          'table': 'prefs',
          'rowId': _prefsRowId,
          'updatedAt': at,
          'payload': cipher.payload,
          'nonce': cipher.nonce,
          '_fingerprint': _fingerprint(data),
        });
      case 'sessions':
        for (final s in await _db.select(_db.sessionRows).get()) {
          final data = {
            'id': s.id,
            'title': s.title,
            'createdAt': s.createdAt,
            'updatedAt': s.updatedAt,
          };
          final cipher = _encryptJson(data);
          rows.add({
            'table': 'sessions',
            'rowId': s.id,
            'updatedAt': s.updatedAt,
            'payload': cipher.payload,
            'nonce': cipher.nonce,
            '_fingerprint': _fingerprint(data),
          });
        }
      case 'messages':
        // 按会话分组：每会话一行，避免消息级行数爆炸
        final all = await _db.select(_db.messageRows).get();
        final bySession = <String, List<Map<String, dynamic>>>{};
        for (final m in all) {
          final list = bySession.putIfAbsent(m.sessionId, () => []);
          list.add({
            'mid': m.mid,
            'sessionId': m.sessionId,
            'role': m.role,
            'content': m.content,
            'toolCallsJson': m.toolCallsJson,
            'toolCallId': m.toolCallId,
            'toolName': m.toolName,
            'imagesJson': jsonEncode(
                await MessageImageStore.instance.resolveJson(m.imagesJson)),
            'reasoning': m.reasoning,
            'createdAt': m.createdAt,
          });
        }
        for (final entry in bySession.entries) {
          final cipher = _encryptJson(entry.value);
          final latest = entry.value.fold<int>(
              0, (a, m) => (m['createdAt'] as num).toInt() > a ? (m['createdAt'] as num).toInt() : a);
          rows.add({
            'table': 'messages',
            'rowId': entry.key,
            'updatedAt': latest,
            'payload': cipher.payload,
            'nonce': cipher.nonce,
            '_fingerprint': _fingerprint(entry.value),
          });
        }
    }
    return rows;
  }

  String _fingerprint(Object data) =>
      sha256.convert(utf8.encode(jsonEncode(data))).toString().substring(0, 32);

  // ---------------- 合并落地 ----------------

  Future<bool> _mergeSession(Map<String, dynamic> remote) async {
    final id = remote['id'] as String? ?? '';
    if (id.isEmpty) return false;
    final local =
        await (_db.select(_db.sessionRows)..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    final rUpdated = (remote['updatedAt'] as num?)?.toInt() ?? 0;
    if (local == null) {
      await _db.into(_db.sessionRows).insert(SessionRowsCompanion.insert(
            id: id,
            title: remote['title'] as String? ?? '',
            createdAt: (remote['createdAt'] as num?)?.toInt() ?? 0,
            updatedAt: rUpdated,
          ));
      return true;
    }
    if (rUpdated > local.updatedAt) {
      await (_db.update(_db.sessionRows)..where((t) => t.id.equals(id))).write(
          SessionRowsCompanion(
              title: Value(remote['title'] as String? ?? local.title),
              updatedAt: Value(rUpdated)));
      return true;
    }
    return false;
  }

  Future<int> _mergeMessages(String sessionId, List<Map> remoteItems) async {
    final localRows = await (_db.select(_db.messageRows)
          ..where((t) => t.sessionId.equals(sessionId)))
        .get();
    final have = localRows.map((m) => m.mid).toSet();
    var added = 0;
    await _db.transaction(() async {
      for (final m in remoteItems) {
        final mid = m['mid'] as String? ?? '';
        if (mid.isEmpty || have.contains(mid)) continue;
        // 备份里是 data URL（自包含），落库时转回文件引用
        final imagesJson = await MessageImageStore.instance
            .storeJson(mid, m['imagesJson'] as String? ?? '[]');
        await _db.into(_db.messageRows).insert(MessageRowsCompanion.insert(
              mid: mid,
              sessionId: m['sessionId'] as String? ?? sessionId,
              role: m['role'] as String? ?? 'user',
              content: m['content'] as String? ?? '',
              toolCallsJson: Value(m['toolCallsJson'] as String? ?? '[]'),
              toolCallId: Value(m['toolCallId'] as String?),
              toolName: Value(m['toolName'] as String?),
              imagesJson: Value(imagesJson),
              reasoning: Value(m['reasoning'] as String?),
              createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
            ));
        added++;
      }
    });
    return added;
  }

  Future<int> _deleteSessionLocal(String sessionId) async {
    final n = await (_db.delete(_db.messageRows)
          ..where((t) => t.sessionId.equals(sessionId)))
        .go();
    await (_db.delete(_db.sessionRows)..where((t) => t.id.equals(sessionId))).go();
    return n;
  }

  /// 从云备份快照恢复某个表（合并语义，复用 [_applyTable]）。
  Future<List<String>> _applyTable(String table, Object data) async {
    switch (table) {
      case 'prefs':
        final m = (data as Map).cast<String, dynamic>();
        return backup.restore(jsonEncode({
          'app': 'orion_agent',
          'backupVersion': BackupService.currentVersion,
          if (m.containsKey('configs')) 'configs': m['configs'],
          if (m.containsKey('mcpServers')) 'mcpServers': m['mcpServers'],
          if (m.containsKey('settings')) 'settings': m['settings'],
        }));
      case 'sessions':
        final list = ((data as Map)['sessions'] as List).cast<Map>();
        var n = 0;
        for (final s in list) {
          if (await _mergeSession(s.cast<String, dynamic>())) n++;
        }
        return ['会话已合并 $n 个'];
      case 'messages':
        final list = ((data as Map)['messages'] as List).cast<Map>();
        final bySession = <String, List<Map>>{};
        for (final m in list) {
          final sid = m['sessionId'] as String? ?? '';
          if (sid.isEmpty) continue;
          bySession.putIfAbsent(sid, () => []).add(m);
        }
        var n = 0;
        for (final e in bySession.entries) {
          n += await _mergeMessages(e.key, e.value);
        }
        return ['消息已合并 $n 条'];
      default:
        throw CloudSyncException('未知表：$table');
    }
  }
}

/// 一轮同步的结果摘要（用于 UI 展示）。
class SyncSummary {
  const SyncSummary({
    required this.pulledSessions,
    required this.pulledMessages,
    required this.pulledPrefs,
    required this.pushedRows,
    required this.deleted,
  });

  final int pulledSessions;
  final int pulledMessages;
  final int pulledPrefs;
  final int pushedRows;
  final int deleted;

  int get pulledTotal => pulledSessions + pulledMessages + pulledPrefs;

  String describe() {
    final parts = <String>[];
    if (pulledTotal > 0) parts.add('拉取 $pulledTotal 项');
    if (deleted > 0) parts.add('删除 $deleted 条');
    if (pushedRows > 0) parts.add('推送 $pushedRows 行');
    return parts.isEmpty ? '已是最新' : parts.join('，');
  }
}

class _CipherText {
  const _CipherText(this.payload, this.nonce);
  final String payload;
  final String nonce;
}

/// 云同步通用错误。
class CloudSyncException implements Exception {
  CloudSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 密钥不匹配（密码错误或密文被篡改）。
class CloudSyncPasswordWrong extends CloudSyncException {
  const CloudSyncPasswordWrong()
      : super('密码不正确：无法解密云端数据（若你改过账号密码，旧数据将无法恢复）');
}
