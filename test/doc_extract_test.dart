// 文档文本提取单测（评估项 U1，v0.2.27-beta）：txt / docx / pdf 兼容提取。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/doc_extract.dart';

Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('文本类文件', () {
    test('txt/md 直读并去首尾空白', () {
      final text = extractDocText('notes.md', bytesOf('  # 标题\n正文\n '));
      expect(text, '# 标题\n正文');
    });

    test('空文本返回 null', () {
      expect(extractDocText('a.txt', bytesOf('   \n')), isNull);
    });

    test('二进制内容（含 NUL）明确拒绝', () {
      expect(
        () => extractDocText('x.bin', Uint8List.fromList([0x78, 0x00, 0x01])),
        throwsA(isA<DocExtractException>()),
      );
    });

    test('.doc 明确提示不支持', () {
      expect(
        () => extractDocText('old.doc', bytesOf('x')),
        throwsA(isA<DocExtractException>()),
      );
    });
  });

  group('docx', () {
    test('解包 word/document.xml 提取段落并还原实体', () {
      final xml = '<?xml version="1.0"?>'
          '<w:document><w:body>'
          '<w:p><w:r><w:t>第一段 &amp; 说明</w:t></w:r>'
          '<w:r><w:t>同行拼接</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>second &lt;line&gt;</w:t></w:r></w:p>'
          '</w:body></w:document>';
      final archive = Archive()
        ..addFile(ArchiveFile('word/document.xml', xml.codeUnits.length,
            utf8.encode(xml)));
      final docx = ZipEncoder().encode(archive)!;

      final text = extractDocText('doc.docx', Uint8List.fromList(docx));
      expect(text, isNotNull);
      expect(text, contains('第一段 & 说明'),
          reason: '段内多个 <w:t> 要拼接、&amp; 要还原，got: $text');
      expect(text, contains('second <line>'));
      expect(text.split('\n'), hasLength(2), reason: '段落之间换行，got: $text');
    });

    test('缺 word/document.xml 明确报错', () {
      final archive = Archive()
        ..addFile(ArchiveFile('other.txt', 2, utf8.encode('hi')));
      final docx = ZipEncoder().encode(archive)!;
      expect(
        () => extractDocText('fake.docx', Uint8List.fromList(docx)),
        throwsA(isA<DocExtractException>()),
      );
    });
  });

  group('pdf（兼容提取）', () {
    String buildPdf(String streamContent, {bool compress = false}) {
      var data = utf8.encode(streamContent);
      if (compress) {
        data = ZLibEncoder().encode(data);
      }
      final header = '%PDF-1.4\n';
      final body = '4 0 obj\n<< /Length ${data.length} >>\nstream\n';
      final footer = '\nendstream\nendobj\n%%EOF\n';
      return utf8.encode(header + body) +
          data +
          utf8.encode(footer);
    }

    test('未压缩内容流：Tj 算子逐行提取', () {
      final pdf = buildPdf('BT (Hello World) Tj (Second line of text) Tj ET');
      final text = extractDocText('a.pdf', Uint8List.fromList(pdf));
      expect(text, isNotNull, reason: '有文本层必须能提出内容');
      expect(text, contains('Hello World'));
      expect(text, contains('Second line of text'));
    });

    test('FlateDecode 压缩流：先 inflate 再提取', () {
      const content =
          'BT (压缩前的中文内容要能读出来，这一句足够长以越过最短门限的检查) Tj ET';
      final pdf = buildPdf(content, compress: true);
      final text = extractDocText('b.pdf', Uint8List.fromList(pdf));
      expect(text, isNotNull);
      expect(text, contains('压缩前的中文内容'));
    });

    test('数组 TJ 算子', () {
      final pdf = buildPdf(
          'BT [(This is an) 120 (ar) 40 (ray)] TJ [(x) 40 (y with more text)] TJ ET');
      final text = extractDocText('c.pdf', Uint8List.fromList(pdf));
      expect(text, isNotNull);
      expect(text, contains('array'));
      expect(text, contains('xy with more text'));
    });

    test('没有文本层（无 stream 或提取结果过短）返回 null', () {
      expect(
          extractDocText(
              'empty.pdf', Uint8List.fromList(utf8.encode('%PDF-1.4\n%%EOF'))),
          isNull);
      expect(
          extractDocText('tiny.pdf',
              Uint8List.fromList(buildPdf('BT (ab) Tj ET'))),
          isNull,
          reason: '提取结果过短（<20 字符）视为失败：扫描件/CID 字体的兜底门限');
    });

    test('非 PDF 魔数明确拒绝', () {
      expect(
        () => extractDocText('fake.pdf', bytesOf('hello world, not a pdf')),
        throwsA(isA<DocExtractException>()),
      );
    });
  });

  test('超过 20MB 上限拒绝', () {
    expect(
      () => extractDocText(
          'big.txt', Uint8List(21 * 1024 * 1024)),
      throwsA(isA<DocExtractException>()),
    );
  });
}
