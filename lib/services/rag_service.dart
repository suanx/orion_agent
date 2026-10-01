import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import 'database.dart';
import 'text_chunker.dart';

/// 一条检索命中：来自哪个文档、原文内容、相似度得分。
class RagHit {
  final String docTitle;
  final String content;
  final double score;

  const RagHit({required this.docTitle, required this.content, required this.score});
}

/// 批量向量化函数：一次请求输入一批文本，返回等长向量列表。
typedef BatchEmbed = Future<List<List<double>>> Function(List<String> inputs);

double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// RAG 知识库服务：文档分块 → 向量化 → SQLite 存储 → 余弦暴力检索。
/// v1 规模（几百块以内）暴力检索足够；后续可换 sqlite-vec。
class RagService {
  RagService(this._db);

  static const _embedBatchSize = 16;
  static const _defaultTopK = 4;
  static const _minScore = 0.2;

  final AppDatabase _db;

  Future<List<KnowledgeDoc>> listDocs() async {
    final rows = await (_db.select(_db.knowledgeDocs)
          ..orderBy([(d) => OrderingTerm.desc(d.createdAt)]))
        .get();
    return rows;
  }

  /// 文档入库：分块 → 分批向量化 → 事务写入，返回文档 id。
  Future<String> addDocument({
    required String title,
    required String text,
    required BatchEmbed embed,
  }) async {
    final parts = chunkText(text);
    if (parts.isEmpty) {
      throw Exception('文档内容为空，无法入库');
    }

    final embeddings = <List<double>>[];
    for (var i = 0; i < parts.length; i += _embedBatchSize) {
      final group = parts.sublist(i, math.min(i + _embedBatchSize, parts.length));
      embeddings.addAll(await embed(group));
    }
    if (embeddings.length != parts.length) {
      throw Exception('Embedding 返回数量（${embeddings.length}）与分块数量（${parts.length}）不一致');
    }

    final id = 'doc_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction(() async {
      await _db.into(_db.knowledgeDocs).insert(KnowledgeDocsCompanion(
            id: Value(id),
            title: Value(title),
            chunkCount: Value(parts.length),
            createdAt: Value(now),
          ));
      for (var i = 0; i < parts.length; i++) {
        await _db.into(_db.knowledgeChunks).insert(KnowledgeChunksCompanion(
              docId: Value(id),
              idx: Value(i),
              content: Value(parts[i]),
              embeddingJson: Value(jsonEncode(embeddings[i])),
            ));
      }
    });
    return id;
  }

  Future<void> deleteDocument(String docId) => _db.transaction(() async {
        await (_db.delete(_db.knowledgeChunks)
              ..where((c) => c.docId.equals(docId)))
            .go();
        await (_db.delete(_db.knowledgeDocs)..where((d) => d.id.equals(docId)))
            .go();
      });

  /// 检索：查询向量化后与全部分块算余弦相似度，返回 topK 条。
  Future<List<RagHit>> search({
    required String query,
    required Future<List<double>> Function(String query) embedOne,
    int topK = _defaultTopK,
  }) async {
    final qv = await embedOne(query);
    if (qv.isEmpty) return const [];

    final docs = {
      for (final d in await (_db.select(_db.knowledgeDocs).get())) d.id: d.title,
    };
    final chunks = await (_db.select(_db.knowledgeChunks)).get();

    final hits = <RagHit>[];
    for (final c in chunks) {
      final vec = (jsonDecode(c.embeddingJson) as List? ?? const [])
          .whereType<num>()
          .map((e) => e.toDouble())
          .toList();
      final score = cosineSimilarity(qv, vec);
      if (score >= _minScore) {
        hits.add(RagHit(
          docTitle: docs[c.docId] ?? c.docId,
          content: c.content,
          score: score,
        ));
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(topK).toList();
  }
}
