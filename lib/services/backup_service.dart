import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database.dart';
import 'message_image_store.dart';

/// 备份与恢复：把用户选中的数据域导出为 JSON 文件，或从文件导入。
///
/// 数据域（与「我的 → 备份与恢复」的四个开关一一对应）：
/// - configs  : AI 供应商配置（**含 API Key**，来自加密存储 llm_configs）
/// - history  : 聊天历史（sessions + messages 两张表全量）
/// - mcp      : MCP 服务器列表
/// - settings : SharedPreferences 全部键值（主题 / TTS / 通知 / 工作区等）
///
/// 导入策略：全量替换（先清空目标域再写入），与「导出即快照」的直觉
/// 一致；导入完成后需要重启应用让内存中的 provider 状态重新加载。
/// 备份文件为明文 JSON（含 API Key），由用户自行保管，不自动上传。
class BackupService {
  BackupService(this._db, this._prefs, this._secure);

  static const currentVersion = 1;
  static const _configsKey = 'llm_configs';

  final AppDatabase _db;
  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  /// 导出：返回备份 JSON 字符串。
  Future<String> export({
    required bool includeConfigs,
    required bool includeHistory,
    required bool includeMcp,
    required bool includeSettings,
  }) async {
    final backup = <String, dynamic>{
      'app': 'orion_agent',
      'backupVersion': currentVersion,
      'createdAt': DateTime.now().toIso8601String(),
    };
    if (includeConfigs) {
      backup['configs'] = jsonDecode(
          await _secure.read(key: _configsKey) ?? '[]');
    }
    if (includeHistory) {
      final sessions = await _db.select(_db.sessionRows).get();
      final messages = await _db.select(_db.messageRows).get();
      backup['sessions'] = [
        for (final s in sessions)
          {
            'id': s.id,
            'title': s.title,
            'createdAt': s.createdAt,
            'updatedAt': s.updatedAt,
          }
      ];
      backup['messages'] = [
        for (final m in messages)
          {
            'mid': m.mid,
            'sessionId': m.sessionId,
            'role': m.role,
            'content': m.content,
            'toolCallsJson': m.toolCallsJson,
            'toolCallId': m.toolCallId,
            'toolName': m.toolName,
            // 图片自 v0.2.27-beta 起落盘为文件、DB 存引用；导出时还原为
            // data URL，保证备份文件自包含（导入到任何设备都能用）
            'imagesJson':
                jsonEncode(await MessageImageStore.instance
                    .resolveJson(m.imagesJson)),
            'reasoning': m.reasoning,
            'createdAt': m.createdAt,
          }
      ];
    }
    if (includeMcp) {
      final rows = await _db.select(_db.mcpServers).get();
      backup['mcpServers'] = [
        for (final r in rows)
          {
            'id': r.id,
            'name': r.name,
            'url': r.url,
            'enabled': r.enabled,
            'createdAt': r.createdAt,
          }
      ];
    }
    if (includeSettings) {
      backup['settings'] = {
        for (final k in _prefs.getKeys()) k: _prefs.get(k),
      };
    }
    return const JsonEncoder.withIndent('  ').convert(backup);
  }

  /// 导入：按备份内容逐域恢复（存在才恢复），返回各域的处理摘要。
  /// 全量替换语义：目标域的现有数据会被备份内容覆盖。
  Future<List<String>> restore(String jsonText) async {
    final summary = <String>[];
    final backup = jsonDecode(jsonText) as Map;
    if (backup['app'] != 'orion_agent') {
      throw Exception('这不是 Orion Agent 的备份文件');
    }

    // ---- AI 供应商 ----
    if (backup['configs'] is List) {
      await _secure.write(
          key: _configsKey, value: jsonEncode(backup['configs']));
      summary.add('AI 供应商配置已恢复');
    }

    // ---- 聊天历史 ----
    if (backup['sessions'] is List && backup['messages'] is List) {
      await _db.transaction(() async {
        await _db.delete(_db.messageRows).go();
        await _db.delete(_db.sessionRows).go();
        for (final s in (backup['sessions'] as List).cast<Map>()) {
          await _db.into(_db.sessionRows).insert(SessionRowsCompanion.insert(
                id: s['id'] as String,
                title: s['title'] as String? ?? '',
                createdAt: (s['createdAt'] as num?)?.toInt() ?? 0,
                updatedAt: (s['updatedAt'] as num?)?.toInt() ?? 0,
              ));
        }
        for (final m in (backup['messages'] as List).cast<Map>()) {
          final mid = m['mid'] as String? ?? '';
          // 备份里是 data URL（自包含），导入时转回文件引用
          final imagesJson = await MessageImageStore.instance
              .storeJson(mid, m['imagesJson'] as String? ?? '[]');
          await _db.into(_db.messageRows).insert(MessageRowsCompanion.insert(
                mid: mid,
                sessionId: m['sessionId'] as String? ?? '',
                role: m['role'] as String? ?? 'user',
                content: m['content'] as String? ?? '',
                toolCallsJson: Value(m['toolCallsJson'] as String? ?? '[]'),
                toolCallId: Value(m['toolCallId'] as String?),
                toolName: Value(m['toolName'] as String?),
                imagesJson: Value(imagesJson),
                reasoning: Value(m['reasoning'] as String?),
                createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
              ));
        }
      });
      summary.add(
          '聊天历史已恢复（${(backup['sessions'] as List).length} 个会话）');
    }

    // ---- MCP 服务器 ----
    if (backup['mcpServers'] is List) {
      await _db.delete(_db.mcpServers).go();
      for (final r in (backup['mcpServers'] as List).cast<Map>()) {
        await _db.into(_db.mcpServers).insert(McpServersCompanion.insert(
              id: r['id'] as String,
              name: r['name'] as String? ?? '',
              url: r['url'] as String? ?? '',
              enabled: Value((r['enabled'] as bool?) ?? true),
              createdAt: (r['createdAt'] as num?)?.toInt() ?? 0,
            ));
      }
      summary.add('MCP 服务器已恢复（${(backup['mcpServers'] as List).length} 个）');
    }

    // ---- 应用设置 ----
    if (backup['settings'] is Map) {
      final settings = (backup['settings'] as Map).cast<String, dynamic>();
      var restored = 0;
      for (final e in settings.entries) {
        final v = e.value;
        // JSON 解码保留 int/double 区分（1.15→double、5→int），逐类型恢复
        if (v is bool) {
          await _prefs.setBool(e.key, v);
        } else if (v is int) {
          await _prefs.setInt(e.key, v);
        } else if (v is double) {
          await _prefs.setDouble(e.key, v);
        } else if (v is String) {
          await _prefs.setString(e.key, v);
        } else if (v is List) {
          await _prefs.setStringList(e.key, v.cast<String>());
        } else {
          continue;
        }
        restored++;
      }
      summary.add('应用设置已恢复（$restored 项）');
    }

    if (summary.isEmpty) {
      throw Exception('备份文件里没有任何可恢复的数据域');
    }
    return summary;
  }

  /// 导出文件写到外部选择的路径（FilePicker.saveFile 返回）。
  Future<void> writeToFile(String path, String jsonText) async {
    final f = File(path);
    await f.writeAsString(jsonText, flush: true);
  }

  /// 从文件读取备份 JSON 文本。
  Future<String> readFromFile(String path) => File(path).readAsString();
}
