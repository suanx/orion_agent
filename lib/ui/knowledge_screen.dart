import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/database.dart';
import '../services/rag_service.dart';

/// 知识库管理页：导入文档（粘贴文本）、查看、删除。
class KnowledgeScreen extends ConsumerStatefulWidget {
  const KnowledgeScreen({super.key});

  @override
  ConsumerState<KnowledgeScreen> createState() => _KnowledgeScreenState();
}

class _KnowledgeScreenState extends ConsumerState<KnowledgeScreen> {
  List<KnowledgeDoc>? _docs;
  bool _ingesting = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final docs = await ref.read(ragServiceProvider).listDocs();
    if (mounted) setState(() => _docs = docs);
  }

  Future<void> _addDocument() async {
    final titleCtrl = TextEditingController();
    final textCtrl = TextEditingController();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('导入文档', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('粘贴文档或笔记文本，导入后会自动分块并向量化。',
                style: TextStyle(
                    fontSize: 13, color: onSurface(context, 0.45))),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                  labelText: '标题（如：产品说明书）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: textCtrl,
              minLines: 6,
              maxLines: 12,
              decoration: const InputDecoration(
                hintText: '在此粘贴文档全文…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('导入并向量化'),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) return;
    final title = titleCtrl.text.trim();
    final text = textCtrl.text.trim();
    if (title.isEmpty || text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('标题和内容不能为空')));
      return;
    }

    setState(() => _ingesting = true);
    try {
      final rag = ref.read(ragServiceProvider);
      final embed = ref.read(batchEmbedProvider);
      await rag.addDocument(title: title, text: text, embed: embed);
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('「$title」已导入知识库')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '导入失败：${e.toString().replaceFirst('Exception: ', '')}')));
      }
    } finally {
      if (mounted) setState(() => _ingesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = _docs;

    return Scaffold(
      appBar: AppBar(title: const Text('知识库')),
      floatingActionButton: _ingesting
          ? const FloatingActionButton.extended(
              onPressed: null,
              icon: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              label: Text('向量化中…'),
            )
          : FloatingActionButton.extended(
              onPressed: _addDocument,
              icon: const Icon(Icons.upload_file),
              label: const Text('导入文档'),
            ),
      body: docs == null
          ? const Center(child: CircularProgressIndicator())
          : docs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '知识库还是空的。\n\n'
                      '导入文档后，对话时会自动检索相关内容作为参考资料，\n'
                      'Agent 也能通过 search_knowledge 工具主动查询。\n\n'
                      '需要先在「设置」中配置 Embedding 模型名。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final d = docs[i];
                    final created =
                        DateTime.fromMillisecondsSinceEpoch(d.createdAt);
                    final date =
                        '${created.year}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')}';
                    return ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(d.title),
                      subtitle: Text('$date · ${d.chunkCount} 个分块'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await ref
                              .read(ragServiceProvider)
                              .deleteDocument(d.id);
                          await _reload();
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
