import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

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
      final vecs = await embed(group);
      // 必须逐批校验长度。只在最后比总数的话，两批互相抵消
      // （首批少 1 条、末批多 1 条）会顺利通过检查，但从 i 起所有分块的向量
      // 全部错位——A 文档检索出 B 文档的内容，且已永久写进数据库。
      if (vecs.length != group.length) {
        throw Exception(
          'Embedding 第 ${i ~/ _embedBatchSize + 1} 批返回 ${vecs.length} 条，'
          '与请求的 ${group.length} 条不符，已中止入库（避免向量与分块错位）',
        );
      }
      embeddings.addAll(vecs);
    }
    if (embeddings.length != parts.length) {
      throw Exception('Embedding 返回数量（${embeddings.length}）与分块数量（${parts.length}）不一致');
    }
    // 维度必须处处一致且非空，否则余弦相似度恒为 0，检索形同虚设。
    final dims = embeddings.map((e) => e.length).toSet();
    if (dims.length != 1 || dims.first == 0) {
      throw Exception('Embedding 返回了不一致或为空的向量维度：$dims');
    }

    final id = uniqueId('doc');
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
    var skipped = 0;
    for (final c in chunks) {
      // 单条脏数据（写入时截断、历史迁移遗留、手动改库）会让 jsonDecode 抛
      // FormatException 并毁掉【整次】检索——所有查询归零，且上游多半是空catch，
      // 用户只看到"AI 不认识我导入的资料了"。这里改为跳过并计数。
      List<double> vec;
      try {
        final decoded = jsonDecode(c.embeddingJson);
        if (decoded is! List) {
          skipped++;
          continue;
        }
        vec = decoded.whereType<num>().map((e) => e.toDouble()).toList();
      } on FormatException {
        skipped++;
        continue;
      }
      // 维度与查询向量不一致时余弦无意义（会被当成 0 分），直接跳过。
      if (vec.length != qv.length || vec.isEmpty) {
        skipped++;
        continue;
      }
      final score = cosineSimilarity(qv, vec);
      if (score >= _minScore) {
        hits.add(RagHit(
          docTitle: docs[c.docId] ?? c.docId,
          content: c.content,
          score: score,
        ));
      }
    }
    if (skipped > 0) {
      debugPrint('RAG: 跳过 $skipped/${chunks.length} 个损坏或维度不符的分块');
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(topK).toList();
  }
}
