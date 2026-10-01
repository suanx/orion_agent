/// 文本分块器：按空行分段，段内合并到不超过 maxLen，超长段落硬切。
/// 纯函数，无副作用，便于单元测试。
List<String> chunkText(String text, {int maxLen = 800}) {
  final normalized = text.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return [];

  final paragraphs = normalized.split(RegExp(r'\n\s*\n'));
  final chunks = <String>[];
  final buf = StringBuffer();

  void flush() {
    final t = buf.toString().trim();
    if (t.isNotEmpty) chunks.add(t);
    buf.clear();
  }

  for (final para in paragraphs) {
    var p = para.trim();
    if (p.isEmpty) continue;

    while (p.length > maxLen) {
      flush();
      chunks.add(p.substring(0, maxLen));
      p = p.substring(maxLen);
    }

    if (buf.isEmpty) {
      buf.write(p);
    } else if (buf.length + 1 + p.length <= maxLen) {
      buf.write('\n');
      buf.write(p);
    } else {
      flush();
      buf.write(p);
    }
  }
  flush();
  return chunks;
}
