import 'dart:convert';

import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/app_log.dart';
import 'package:orion_agent/services/backup_service.dart';
import 'package:orion_agent/services/database.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BackupService 导出/导入回归测试（history / mcp / settings 三个数据域，
/// 全部走纯本地存储——in-memory drift + mock prefs，不碰加密存储）。
///
/// configs（AI 供应商）走 flutter_secure_storage，测试环境无原生通道，
/// 该域不参与任何用例（传入实例但永不触达）；其写读由真机验证。
void main() {
  late AppDatabase db;
  late BackupService svc;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // 仅注入实例，所有用例都不选择 configs 域，secure storage 不会被调用
    svc = BackupService(db, prefs, const FlutterSecureStorage());
  });

  tearDown(() => db.close());

  Future<void> seedDb() async {
    await db.into(db.sessionRows).insert(SessionRowsCompanion.insert(
          id: 's1',
          title: '测试会话',
          createdAt: 1000,
          updatedAt: 2000,
        ));
    await db.into(db.messageRows).insert(MessageRowsCompanion.insert(
          mid: 'm1',
          sessionId: 's1',
          role: 'user',
          content: '你好',
          createdAt: 1500,
        ));
    await db.into(db.mcpServers).insert(McpServersCompanion.insert(
          id: 'mcp1',
          name: '文件服务',
          url: 'http://127.0.0.1:3000/mcp',
          createdAt: 1200,
        ));
  }

  test('导出：JSON 结构包含所选域且内容完整', () async {
    await seedDb();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', 'dark');
    await prefs.setDouble('chat_font_scale', 1.15);
    await prefs.setBool('tts_enabled', false);
    await prefs.setInt('ctx_budget', 100000);

    final text = await svc.export(
      includeConfigs: false,
      includeHistory: true,
      includeMcp: true,
      includeSettings: true,
    );
    final backup = jsonDecode(text) as Map;

    expect(backup['app'], 'orion_agent');
    expect(backup['backupVersion'], BackupService.currentVersion);
    expect((backup['sessions'] as List).length, 1);
    expect((backup['sessions'] as List).first['title'], '测试会话');
    expect((backup['messages'] as List).length, 1);
    expect((backup['messages'] as List).first['content'], '你好');
    expect((backup['mcpServers'] as List).length, 1);
    final settings = (backup['settings'] as Map).cast<String, dynamic>();
    expect(settings['theme_mode'], 'dark');
    // double 值在 JSON 里保持小数，恢复时才能区分 int/double
    expect(settings['chat_font_scale'], 1.15);
    expect(settings['tts_enabled'], false);
    expect(settings['ctx_budget'], 100000);
    expect(backup.containsKey('configs'), isFalse, reason: '未选中的域不应出现');
  });

  test('导入：全量替换恢复 DB 行与 prefs（含类型保真）', () async {
    await seedDb();
    final text = await svc.export(
      includeConfigs: false,
      includeHistory: true,
      includeMcp: true,
      includeSettings: false,
    );

    // 破坏现场：清空 DB，另写一个将被备份覆盖的 prefs 值
    await (db.delete(db.sessionRows)).go();
    await (db.delete(db.messageRows)).go();
    await (db.delete(db.mcpServers)).go();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', 'light');
    await prefs.setDouble('chat_font_scale', 1.3);

    final summary = await svc.restore(text);

    expect(summary.join('\n'), contains('聊天历史'));
    expect(summary.join('\n'), contains('MCP 服务器'));

    final sessions = await db.select(db.sessionRows).get();
    final messages = await db.select(db.messageRows).get();
    final mcps = await db.select(db.mcpServers).get();
    expect(sessions, hasLength(1));
    expect(sessions.single.title, '测试会话');
    expect(messages.single.content, '你好');
    expect(messages.single.sessionId, 's1');
    expect(mcps.single.name, '文件服务');
    expect(mcps.single.enabled, isTrue);
  });

  test('设置域导入：int/double/bool/string 保真（回归：曾统一 setInt 丢 double）',
      () async {
    final backup = jsonEncode({
      'app': 'orion_agent',
      'backupVersion': 1,
      'settings': {
        'theme_mode': 'dark',
        'chat_font_scale': 1.15,
        'tts_enabled': false,
        'ctx_budget': 100000,
        'recent_texts': ['a', 'b'],
      },
    });

    final summary = await svc.restore(backup);
    expect(summary.join('\n'), contains('应用设置已恢复（5 项）'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
    expect(prefs.getDouble('chat_font_scale'), 1.15);
    expect(prefs.getBool('tts_enabled'), isFalse);
    expect(prefs.getInt('ctx_budget'), 100000);
    expect(prefs.getStringList('recent_texts'), ['a', 'b']);
  });

  test('导入：非 Orion 备份文件与空数据域都明确报错', () async {
    expect(() => svc.restore(jsonEncode({'app': 'other_app'})),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'msg', contains('不是 Orion Agent 的备份文件'))));
    expect(
        () => svc.restore(
            jsonEncode({'app': 'orion_agent', 'backupVersion': 1})),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg',
            contains('没有任何可恢复的数据域'))));
  });

  test('AppLog：环形缓冲上限 2000 条，导出文本可读', () {
    // 上限在 lib/services/app_log.dart 的 _maxEntries（2000）。
    // 写 2010 条触发裁剪；缓冲里即便已有更早条目也全在被挤出之列，
    // 首条稳定为 event-10。
    for (var i = 0; i < 2010; i++) {
      AppLog.i('event-$i');
    }
    final text = AppLog.asText();
    final lines = text.split('\n');
    expect(lines.length, 2000, reason: '缓冲上限应裁剪到 2000 条');
    expect(lines.last, contains('event-2009'), reason: '应保留最新的条目');
    expect(lines.first, contains('event-10'), reason: '最旧的应被挤出');
    // event-0~9 应被挤出（精确匹配整行，避免 event-10+ 子串误判）
    expect(lines.any((l) => l.endsWith('event-9]') || l.endsWith('event-9')),
        isFalse,
        reason: '缓冲外最旧的 10 条不应残留');
  });
}
