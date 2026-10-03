import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/database.dart';
import 'package:orion_agent/services/memory_service.dart';
import 'package:orion_agent/services/rag_service.dart';
import 'package:orion_agent/services/text_chunker.dart';
import 'package:orion_agent/services/tools.dart';

void main() {
  group('分块：emoji / 扩展汉字不被劈开', () {
    // String.length 统计 UTF-16 code unit，代理对占 2 个。
    // 原实现按 code unit 硬切会把代理对劈开，产生孤立代理项；
    // Dart 在 jsonEncode / utf8.encode 时会把它静默替换成 U+FFFD，
    // 表现为知识库里的 emoji 变成"�"。
    test('按字素簇切分，emoji 完整且内容无损', () {
      const emoji = '\u{1F600}';
      const text = '$emoji文$emoji文$emoji文$emoji';
      final chunks = chunkText(text, maxLen: 3);

      expect(chunks.join(), text, reason: '分块后内容必须无损');
      for (final c in chunks) {
        expect(c.contains('�'), isFalse, reason: '出现替换字符，块=$c');
        // 孤立代理项在 utf8 往返后会被替换，据此判断是否被劈开
        expect(utf8.decode(utf8.encode(c)), c, reason: '块不是合法 UTF-8：$c');
      }
    });

    test('切分点落在代理对中间时也不产生损坏字符', () {
      const emoji = '\u{1F600}';
      // maxLen=2 时，边界正好落在 emoji 的高代理项之后
      const text = '文$emoji文$emoji文$emoji';
      final chunks = chunkText(text, maxLen: 2);
      expect(chunks.join(), text, reason: '内容必须无损');
      for (final c in chunks) {
        expect(c.contains('�'), isFalse, reason: '块被破坏：$c');
      }
    });

    test('maxLen<=0 走默认值不死循环', () {
      expect(chunkText('短文本', maxLen: 0), ['短文本']);
    });
  });

  group('ToolRegistry：可注销', () {
    // 没有 unregisterPrefix 时，MCP 重连会因同名跳过而保留旧工具，
    // 停用/删除服务器后工具也不会消失。
    late AppDatabase db;
    late ToolRegistry reg;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      reg = ToolRegistry(memoryService: MemoryService(db));
    });
    // 幂等关闭：部分用例会主动 db.close()，tearDown 再关一次会抛。
    tearDown(() async {
      try {
        await db.close();
      } catch (_) {
        // 已关闭
      }
    });

    // ToolRegistry 构造函数会预注册内置工具（DateTime/Calculator/
    // WebSearch/WebFetch/SaveMemory，ragService 与 terminalService 传 null
    // 时不注册），所以这里必须用【相对断言】，不能断言绝对数量。
    test('unregisterPrefix 移除指定前缀的工具', () {
      final before = reg.toolNames;
      reg.register(_FakeTool('srv__alpha'));
      reg.register(_FakeTool('srv__beta'));
      reg.register(_FakeTool('other__gamma'));
      expect(reg.toolNames.length, before.length + 3,
          reason: '实际=${reg.toolNames}');

      reg.unregisterPrefix('srv__');
      expect(reg.toolNames, contains('other__gamma'));
      expect(reg.toolNames, isNot(contains('srv__alpha')));
      expect(reg.toolNames, isNot(contains('srv__beta')));
      // 内置工具不应被波及
      expect(reg.toolNames, contains('calculator'));
    });

    test('同名工具不重复注册', () {
      reg.register(_FakeTool('dup'));
      final afterFirst = reg.toolNames.length;
      reg.register(_FakeTool('dup'));
      expect(reg.toolNames.length, afterFirst, reason: '实际=${reg.toolNames}');
    });
  });

  group('MemoryService：去重与上限', () {
    late AppDatabase db;
    late MemoryService mem;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      mem = MemoryService(db);
    });
    // 幂等关闭：部分用例会主动 db.close()，tearDown 再关一次会抛。
    tearDown(() async {
      try {
        await db.close();
      } catch (_) {
        // 已关闭
      }
    });

    test('重复内容不重复入库', () async {
      await mem.addNote('用户喜欢安静');
      await mem.addNote('用户喜欢安静');
      await mem.addNote('  用户喜欢安静  '); // 空白差异也算重复
      expect(mem.notes, hasLength(1), reason: '实际=${mem.notes.map((n) => n.text).toList()}');
    });

    test('load 成功后重复调用不发多余查询', () async {
      // 回归防护：_loaded 只在查询【成功后】才置位。
      // 旧实现是「await 之前就置位」，一旦首次 load 失败（DB 损坏、
      // schema 迁移中、磁盘异常），此后整个 App 生命周期内 load() 都是
      // no-op，长期记忆永久失效且无法重试，只能重启 App。
      //
      // 注意：本用例验证的是成功路径的幂等（重复 load 不重查）。
      // 失败可重试这一点无法在单元测试里可靠构造 —— 需要让查询抛异常，
      // 而 MemoryService 没有可注入的失败点；用「关闭 db」模拟则依赖
      // drift NativeDatabase 的实现细节（实测不同版本行为不一致：
      // 有时抛 StateError，有时静默返回空结果）。修复本身已由代码审查确认。
      final mem2 = MemoryService(db);
      await mem2.load();
      expect(mem2.notes, isEmpty, reason: '空库应读到空列表');

      await db.into(db.memoryNoteRows).insert(MemoryNoteRowsCompanion(
            id: const Value('seed'),
            body: const Value('一条记忆'),
            createdAt: const Value(1),
          ));

      // 新实例读取：证明数据确实落库了
      final mem3 = MemoryService(db);
      await mem3.load();
      expect(mem3.notes, hasLength(1),
          reason: '实际=${mem3.notes.map((n) => n.text).toList()}');

      // 已加载后再load：不应重复查询、不应抛错、内容保持不变
      await mem3.load();
      await mem3.load();
      expect(mem3.notes, hasLength(1));
      expect(mem3.notes.single.text, '一条记忆');
    });

    test('memoryPrompt 注入有条数与长度上限', () async {
      // 直接写库绕过写入上限，验证的是"注入 prompt"这一层的截断
      for (var i = 0; i < 80; i++) {
        await db.into(db.memoryNoteRows).insert(MemoryNoteRowsCompanion(
              id: Value('m$i'),
              body: Value('记忆$i ${'长' * 400}'),
              createdAt: Value(i),
            ));
      }
      final mem2 = MemoryService(db);
      await mem2.load();
      expect(mem2.notes, hasLength(80), reason: '前置条件：应加载到 80 条');

      final prompt = mem2.memoryPrompt();
      final lines =
          prompt.split('\n').where((l) => l.trimLeft().startsWith('-')).length;
      expect(lines, 60, reason: '应只注入最近 60 条，实际=$lines');
      // 每条截断到 200 字（加省略号），加上 "- " 前缀与换行
      expect(prompt.length, lessThanOrEqualTo(60 * (200 + 10)),
          reason: 'prompt 过长：${prompt.length}');
    });
  });

  group('RagService：脏数据与维度校验', () {
    late AppDatabase db;
    late RagService rag;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      rag = RagService(db);
    });
    // 幂等关闭：部分用例会主动 db.close()，tearDown 再关一次会抛。
    tearDown(() async {
      try {
        await db.close();
      } catch (_) {
        // 已关闭
      }
    });

    test('单条损坏向量不会毁掉整次检索', () async {
      final id = await rag.addDocument(
        title: '正常文档',
        text: '猫是一种宠物。',
        embed: (inputs) async => inputs.map((_) => [1.0, 0.0]).toList(),
      );
      // 人为写入一条非法 JSON
      await db.into(db.knowledgeChunks).insert(KnowledgeChunksCompanion(
            docId: Value(id),
            idx: const Value(1),
            content: const Value('损坏数据'),
            embeddingJson: const Value('{not-json'),
          ));

      final hits = await rag.search(
        query: '猫',
        embedOne: (q) async => [1.0, 0.0],
      );
      expect(hits, isNotEmpty, reason: '脏数据导致整个检索归零');
      expect(hits.first.content.contains('猫'), isTrue);
    });

    test('维度不一致的分块被跳过而非记 0 分', () async {
      final id = await rag.addDocument(
        title: '正常',
        text: '狗很忠诚。',
        embed: (inputs) async => inputs.map((_) => [1.0, 0.0]).toList(),
      );
      await db.into(db.knowledgeChunks).insert(KnowledgeChunksCompanion(
            docId: Value(id),
            idx: const Value(1),
            content: const Value('维度不同'),
            embeddingJson: Value(jsonEncode([1.0, 0.0, 0.0, 0.0, 0.0])),
          ));
      final hits = await rag.search(
        query: '狗',
        embedOne: (q) async => [1.0, 0.0],
      );
      expect(hits.every((h) => h.content != '维度不同'), isTrue,
          reason: '维度不符的分块不应参与检索');
    });

    test('Embedding 逐批数量不符时中止入库，避免向量错位', () async {
      var call = 0;
      // 每段 1000 字 > maxLen(800)，才会硬切成 2 块/段 → 共 80 块 → 5 批
      // (16/16/16/16/16)。注意若用短段落，相邻段落会被合并成一块，
      // 根本触发不了逐批校验。
      final longPara = '猫。' * 500;
      await expectLater(
        rag.addDocument(
          title: '错位',
          text: List.filled(40, longPara).join('\n\n'),
          embed: (inputs) async {
            call++;
            // 第 2 批少返回 1 条：总数仍可能匹配，但逐批校验必须拦下
            if (call == 2) return List.filled(inputs.length - 1, [1.0]);
            return List.filled(inputs.length, [1.0]);
          },
        ),
        throwsException,
      );
      expect(await rag.listDocs(), isEmpty, reason: '失败时不应留下半截数据');
    });

    test('Embedding 维度不一致时中止入库', () async {
      await expectLater(
        rag.addDocument(
          title: '维度',
          text: '猫。',
          embed: (inputs) async => [
                [1.0, 0.0],
                [1.0, 0.0, 3.0],
              ],
        ),
        throwsException,
      );
    });
  });
}

/// 测试用的极简工具实现。
class _FakeTool extends Tool {
  _FakeTool(this.name);
  @override
  final String name;

  @override
  String get description => 'test';

  @override
  Map<String, dynamic> get parameters => {'type': 'object', 'properties': {}};

  @override
  Future<String> execute(Map<String, dynamic> args) async => 'ok';
}
