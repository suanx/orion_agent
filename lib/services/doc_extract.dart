import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 知识库文件导入的文本提取（评估项 U1，v0.2.27-beta）。
///
/// 按扩展名分派，尽力而为：
/// - 文本类（txt/md/代码/日志/csv/json/yaml/html…）：UTF-8 直读
/// - docx：解包读 word/document.xml，按段落合并 <w:t> 文本
/// - pdf：兼容提取——inflate 内容流 + Tj/TJ 显示算子；扫描件/加密/
///   CID 字体的 PDF 提不出文本，返回 null 由 UI 提示改用粘贴
///
/// 抛 [DocExtractException] 表示该文件类型无法处理；返回 null 表示
/// 类型支持但没提出有效文本（UI 提示换粘贴方式）。
class DocExtractException implements Exception {
  DocExtractException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 支持按 UTF-8 直读的扩展名（小写、不含点）。
const _textExtensions = {
  'txt', 'md', 'markdown', 'log', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml',
  'html', 'htm', 'ini', 'conf', 'toml', 'sql', 'dart', 'py', 'js', 'ts',
  'java', 'kt', 'kts', 'c', 'h', 'cpp', 'hpp', 'go', 'rs', 'rb', 'php',
  'sh', 'bat', 'ps1', 'css', 'scss', 'vue', 'svelte',
};

/// 提取文本。失败抛 [DocExtractException]；提出内容为空返回 null。
String? extractDocText(String fileName, Uint8List bytes) {
  if (bytes.length > 20 * 1024 * 1024) {
    throw DocExtractException('文件超过 20MB 上限');
  }
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();

  if (ext == 'pdf') return _extractPdf(bytes);
  if (ext == 'docx') return _extractDocx(bytes);
  if (ext == 'doc') {
    throw DocExtractException('旧版 .doc 不支持，请先另存为 .docx 或粘贴文本');
  }

  // 其余一律按文本尝试：出现 NUL 字节基本就是二进制，直接拒绝
  final text = utf8.decode(bytes, allowMalformed: true);
  if (text.contains('\x00')) {
    throw DocExtractException('不支持的文件类型（.$ext），请转换为 txt / md / docx / pdf');
  }
  if (ext.isNotEmpty && !_textExtensions.contains(ext)) {
    // 未知扩展名但内容是可读文本——宽容收下（用户可能有各种笔记格式）
    if (text.trim().isEmpty) return null;
  }
  final cleaned = text.trim();
  return cleaned.isEmpty ? null : cleaned;
}

// ---------------- docx ----------------

String? _extractDocx(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw DocExtractException('不是有效的 docx 文件（解包失败）');
  }
  final file = archive.findFile('word/document.xml');
  if (file == null) {
    throw DocExtractException('不是有效的 docx 文件（缺少正文）');
  }
  final xml = utf8.decode(file.content, allowMalformed: true);
  final lines = <String>[];
  // 段落以 </w:p> 分界；段内所有 <w:t> 文本直接拼接
  for (final para in xml.split('</w:p>')) {
    final t = RegExp(r'<w:t[^>]*>([^<]*)</w:t>')
        .allMatches(para)
        .map((m) => m.group(1)!)
        .join();
    final decoded = _decodeXmlEntities(t);
    if (decoded.trim().isNotEmpty) lines.add(decoded);
  }
  final text = lines.join('\n').trim();
  return text.isEmpty ? null : text;
}

String _decodeXmlEntities(String s) {
  return s
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

// ---------------- pdf（尽力而为） ----------------

/// 从 PDF 字节里提取文本：找到所有 stream…endstream 内容段，
/// FlateDecode 的先 inflate，再从内容流里抠 Tj / TJ 显示算子的字符串。
///
/// 局限（设计上接受）：不解析字体编码，CID/自定义编码字体的中文 PDF
/// 会提出乱码或空——靠「结果过短即视为失败」的门限兜底；扫描件是图片
/// 本来就没有文本层。这两类都返回 null，UI 提示用户改用粘贴。
String? _extractPdf(Uint8List bytes) {
  // '%PDF-' 魔数
  if (bytes.length < 5 ||
      bytes[0] != 0x25 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x44 ||
      bytes[3] != 0x46 ||
      bytes[4] != 0x2D) {
    throw DocExtractException('不是有效的 PDF 文件');
  }
  // PDF 结构以 latin1 逐字节映射处理，避免多字节解码破坏偏移
  final raw = latin1.decode(bytes, allowInvalid: true);
  final buf = StringBuffer();
  var idx = 0;
  var foundAny = false;

  while (true) {
    final s = raw.indexOf('stream', idx);
    if (s < 0) break;
    var cs = s + 'stream'.length;
    if (cs < raw.length && raw[cs] == '\r') cs++;
    if (cs < raw.length && raw[cs] == '\n') cs++;
    final e = raw.indexOf('endstream', cs);
    if (e < 0) break;
    idx = e + 'endstream'.length;
    // 去掉 endstream 前的 EOL
    var end = e;
    while (end > cs && (raw[end - 1] == '\n' || raw[end - 1] == '\r')) {
      end--;
    }
    final segBytes = Uint8List.fromList(
        raw.substring(cs, end).codeUnits.where((c) => c <= 0xFF).toList());

    String content;
    try {
      // FlateDecode = zlib；非 zlib 开头的段（图片等）inflate 会抛，落到原文
      content = utf8.decode(zlib.decode(segBytes), allowMalformed: true);
    } catch (_) {
      content = raw.substring(cs, end);
    }
    final piece = _pdfShowOperators(content);
    if (piece.isNotEmpty) {
      foundAny = true;
      buf.writeln(piece);
    }
  }
  if (!foundAny) return null;
  final text = buf.toString().trim();
  // 门限：提不出足够文本视为失败（扫描件 / CID 字体的情况）
  return text.length < 20 ? null : text;
}

/// 从 PDF 内容流里抠文本显示算子的字符串字面量。
String _pdfShowOperators(String content) {
  final buf = StringBuffer();
  // 数组形式 [(He) 250 (llo)] TJ：数组内的字符串后跟的是字距数字而非
  // 算子名，不能要求 Tj 后缀，直接取数组内所有 (...) 字面量
  final arrayRe = RegExp(r'\[(.*?)\]\s*TJ', dotAll: true);
  final strRe = RegExp(r'\(((?:[^()\\]|\\.)*)\)');
  // 单串形式 (…) Tj（含换行变体 ' 与 "）；带后缀要求是为了不把
  // 非显示算子的 operand 字符串误当正文
  final singleRe = RegExp(r'''\(((?:[^()\\]|\\.)*)\)\s*(?:Tj|'|")''');
  for (final m in arrayRe.allMatches(content)) {
    final parts =
        strRe.allMatches(m.group(1)!).map((x) => _pdfUnescape(x.group(1)!));
    final line = parts.join();
    if (line.trim().isNotEmpty) buf.writeln(line);
  }
  // 已按数组处理的之外，补单串 Tj（含不含数组的普通行）
  final withoutArrays = content.replaceAll(arrayRe, '');
  for (final m in singleRe.allMatches(withoutArrays)) {
    final line = _pdfUnescape(m.group(1)!);
    if (line.trim().isNotEmpty) buf.writeln(line);
  }
  return buf.toString();
}

/// PDF 字符串字面量的转义还原：\( \) \\ \n \r \t \ooo 八进制。
String _pdfUnescape(String s) {
  return s.replaceAllMapped(RegExp(r'\\([nrtbf()\\]|[0-7]{1,3})'), (m) {
    final g = m.group(1)!;
    switch (g) {
      case 'n':
        return '\n';
      case 'r':
        return '\r';
      case 't':
        return '\t';
      case 'b':
        return '\b';
      case 'f':
        return '\f';
      default:
        if (g.length <= 3 && RegExp(r'^[0-7]+$').hasMatch(g)) {
          return String.fromCharCode(int.parse(g, radix: 8));
        }
        return g;
    }
  });
}
