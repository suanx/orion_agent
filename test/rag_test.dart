import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/services/database.dart';
import 'package:pocket_agent/services/rag_service.dart';
import 'package:pocket_agent/services/text_chunker.dart';

/// 伪向量化：按「猫」「狗」出现次数生成二维向量，确定且可预测。
Future<List<List<double>>> fakeEmbed(List<String> inputs) async {
  return inputs.map((t) {
    final cat = '猫'.allMatches(t).length.toDouble();
    final dog = '狗'.allMatches(t).length.toDouble();
    return [cat, dog];
  }).toList();
}

void main() {
  late AppDatabase db;
  late RagService rag;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    rag = RagService(db);
  });
  tearDown(() async => db.close());

  group('chunkText', () {
    test('短文本保持单块', () {
      expect(chunkText('这是一段短文本。'), ['这是一段短文本。']);
    });

    test('空文本返回空列表', () {
      expect(chunkText('   \n \n'), isEmpty);
    });

    test('超长文本硬切且不超过 maxLen', () {
      final text = '字' * 2500;
      final chunks = chunkText(text, maxLen: 800);
      expect(chunks.length, 4); // 800 + 800 + 800 + 100
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(800));
      }
      expect(chunks.join('').length, 2500);
    });

    test('多个段落合并成块，不超上限', () {
      final para = '段落内容。\n\n';
      final text = para * 30; // 30 段，每段 5 字
      final chunks = chunkText(text, maxLen: 800);
      expect(chunks.length, 1); // 30*5 + 29 个换行 = 179 字，全部合进一块
      expect(chunks.first.length, 179);
    });
  });

  group('RagService', () {
    test('文档入库后可按语义检索命中', () async {
      final id = await rag.addDocument(
        title: '宠物笔记',
        text: '猫是一种常见的家养宠物，性格独立。\n\n猫喜欢在白天睡觉，夜间活动。\n\n狗是忠诚的伙伴，需要每天遛弯。',
        embed: fakeEmbed,
      );
      expect(id, isNotEmpty);

      final docs = await rag.listDocs();
      expect(docs, hasLength(1));
      expect(docs.single.title, '宠物笔记');
      expect(docs.single.chunkCount, 3);

      final hits = await rag.search(
        query: '猫的习性',
        embedOne: (q) async => (await fakeEmbed([q])).first,
      );
      expect(hits, isNotEmpty);
      expect(hits.first.content.contains('猫'), isTrue);
      // 相关性排序：含猫的块应排在含狗的块前面
      final catIdx = hits.indexWhere((h) => h.content.contains('狗'));
      if (catIdx != -1) {
        expect(catIdx, greaterThanOrEqualTo(1));
      }
    });

    test('无关查询返回空结果', () async {
      await rag.addDocument(
        title: '宠物笔记',
        text: '猫喜欢睡觉。\n\n狗喜欢遛弯。',
        embed: fakeEmbed,
      );
      // 「鱼」在词表中无分量 → 零向量 → 相似度 0，低于阈值
      final hits = await rag.search(
        query: '鱼',
        embedOne: (q) async => (await fakeEmbed([q])).first,
      );
      expect(hits, isEmpty);
    });

    test('删除文档后块一并删除', () async {
      final id = await rag.addDocument(
        title: '笔记',
        text: '猫喜欢睡觉。',
        embed: fakeEmbed,
      );
      await rag.deleteDocument(id);
      expect(await rag.listDocs(), isEmpty);
      final hits = await rag.search(
        query: '猫',
        embedOne: (q) async => (await fakeEmbed([q])).first,
      );
      expect(hits, isEmpty);
    });

    test('空文本入库抛异常', () async {
      await expectLater(
        rag.addDocument(title: '空', text: '  ', embed: fakeEmbed),
        throwsException,
      );
    });
  });

  test('cosineSimilarity 基本性质', () {
    expect(cosineSimilarity([1, 0], [1, 0]), closeTo(1, 1e-9));
    expect(cosineSimilarity([1, 0], [0, 1]), closeTo(0, 1e-9));
    expect(cosineSimilarity([1, 0], [-1, 0]), closeTo(-1, 1e-9));
    expect(cosineSimilarity([0, 0], [1, 0]), 0); // 零向量安全
    expect(cosineSimilarity([1], [1, 2]), 0); // 维度不同安全
  });
}
