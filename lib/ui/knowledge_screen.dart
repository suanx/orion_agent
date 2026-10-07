import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme.dart';
import 'glass.dart';
import '../providers/providers.dart';
import '../services/database.dart';
import '../services/doc_extract.dart';

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
    // 入口二选一（评估项 U1，v0.2.27-beta）：文件导入（txt/md/代码日志、
    // docx、pdf）或传统的粘贴文本。
    final choice = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        backgroundColor: Colors.transparent,
        title: const Text('导入文档'),
        content: Text(
          '支持 txt / md / 代码日志（UTF-8）、docx、pdf。\n'
          'pdf 为尽力提取，扫描件与加密文档提不出文本，请改用粘贴。',
          style: TextStyle(fontSize: 13, color: onSurface(ctx, 0.45)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('file'),
            child: const Text('选择文件'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('paste'),
            child: const Text('粘贴文本'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'file') {
      await _importFromFile();
    } else if (choice == 'paste') {
      await _importByPaste();
    }
  }

  /// 文件导入：选择 → 按类型提取文本 → 走统一的分块向量化。
  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
      );
      if (!mounted) return;
      final file = result?.files.singleOrNull;
      if (file == null) return;
      if (file.size > 20 * 1024 * 1024) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('文件超过 20MB 上限')));
        return;
      }
      setState(() => _ingesting = true);
      try {
        final bytes = await File(file.path!).readAsBytes();
        final text = extractDocText(file.name, bytes);
        if (text == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('没能从该 PDF 提取出文本（可能是扫描件或加密），'
                    '请改用「粘贴文本」导入')));
          }
          return;
        }
        final dot = file.name.lastIndexOf('.');
        final title = dot > 0 ? file.name.substring(0, dot) : file.name;
        await _ingest(title: title.isEmpty ? file.name : title, text: text);
      } finally {
        if (mounted) setState(() => _ingesting = false);
      }
    } on DocExtractException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('导入失败：${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  /// 粘贴文本导入（原入口）。
  Future<void> _importByPaste() async {
    final titleCtrl = TextEditingController();
    final textCtrl = TextEditingController();

    // 双输入框弹窗语义特殊（标题 + 多行正文），不迁移 showGlassTextDialog；
    // 输入值随 pop 带出 + whenComplete dispose（P2-6）。
    final saved = await showGlassDialog<(String, String)>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        backgroundColor: Colors.transparent,
        title: const Text('导入文档'),
        // 内层不包 SingleChildScrollView（外层 glassAlertDialog 已滚动，
        // 嵌套会抢手势）：Column 直接交给外层
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
              onPressed: () => Navigator.of(ctx)
                  .pop((titleCtrl.text.trim(), textCtrl.text.trim())),
              child: const Text('导入并向量化'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      titleCtrl.dispose();
      textCtrl.dispose();
    });

    if (saved == null || !mounted) return;
    final title = saved.$1;
    final text = saved.$2;
    if (title.isEmpty || text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('标题和内容不能为空')));
      return;
    }
    await _ingest(title: title, text: text);
  }

  /// 统一入库：分块 → 向量化 → 刷新列表。超长文本截断并提示。
  Future<void> _ingest({required String title, required String text}) async {
    var content = text;
    const maxChars = 500000;
    if (content.length > maxChars) {
      content = content.substring(0, maxChars);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('文本超长，已截断到前 $maxChars 字符')));
      }
    }
    setState(() => _ingesting = true);
    try {
      final rag = ref.read(ragServiceProvider);
      final embed = ref.read(batchEmbedProvider);
      await rag.addDocument(title: title, text: content, embed: embed);
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
