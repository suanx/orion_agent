import 'package:characters/characters.dart';

/// 文本分块器：按空行分段，段内合并到不超过 maxLen，超长段落硬切。
/// 纯函数，无副作用，便于单元测试。
List<String> chunkText(String text, {int maxLen = 800}) {
  // 防御 maxLen<=0：原实现里 while (p.length > maxLen) 会取 substring(0, 0)，
  // p 不变而循环条件恒成立，直接死循环。
  if (maxLen <= 0) maxLen = 800;
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

    // 必须按【字素簇】而非 code unit 硬切。String.length 统计 UTF-16 code unit，
    // 代理对（emoji、扩展汉字）占 2 个；边界落在代理对中间时 substring 会把它劈开。
    // 实测后果：'文😀文😀文' 按 maxLen=2 切开会得到含孤立高代理项（0xD83D）的块，
    // Dart 在 jsonEncode / utf8.encode 时会把它静默替换成 U+FFFD，
    // 表现为知识库里的 emoji 变成"�"——不报错，只是内容被悄悄改坏。
    while (p.characters.length > maxLen) {
      flush();
      chunks.add(p.characters.take(maxLen).toString());
      p = p.characters.skip(maxLen).toString();
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
