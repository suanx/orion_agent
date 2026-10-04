import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/skill_search_service.dart';

/// 假 HTTP 适配器：按 URL 返回预置文本或抛错，全程不碰网络。
/// SkillSearchService 通过 Dio.get 拉源，而 Dio 的构造函数是 factory
/// 无法子类化，因此替换底层的 HttpClientAdapter（dio 官方 mock 注入点），
/// 上层 request/transform/validateStatus 全部走真实路径。
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter({this.bodies = const {}, this.failingUrls = const {}});

  /// url → 响应正文（200）。
  final Map<String, String> bodies;

  /// 命中即抛异常的 url（模拟网络故障）。
  final Set<String> failingUrls;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    if (failingUrls.contains(url)) {
      throw Exception('模拟网络故障：$url');
    }
    return ResponseBody.fromString(bodies[url] ?? '', 200);
  }

  @override
  void close({bool force = false}) {}
}

SkillSearchService buildService(Map<String, String> bodies,
    {Set<String> failingUrls = const {}}) {
  final dio = Dio()..httpClientAdapter = FakeAdapter(
    bodies: bodies,
    failingUrls: failingUrls,
  );
  return SkillSearchService(
    dio: dio,
    sources: [
      for (final url in bodies.keys)
        SkillSource(
          name: '源:$url',
          url: url,
          format: url.endsWith('.json') ? 'json' : 'csv',
        ),
    ],
  );
}

const fakeJsonUrl = 'https://test.local/prompts-zh.json';
const fakeCsvUrl = 'https://test.local/prompts.csv';

void main() {
  group('CSV 状态机解析（经 search 公开入口）', () {
    test('引号包裹字段含逗号，且 act 表头被跳过', () async {
      final svc = buildService({
        fakeCsvUrl: 'act,prompt\n'
            '"helper, pro","step 1, step 2"\n',
      });
      final hits = await svc.search('helper');
      expect(hits, hasLength(1));
      expect(hits.single.title, 'helper, pro');
      expect(hits.single.prompt, 'step 1, step 2');
    });

    test('字段内换行完整保留（\\r 不产生多余内容）', () async {
      final svc = buildService({
        fakeCsvUrl: 'act,prompt\n"liner","line1\nline2"\n',
      });
      final hits = await svc.search('liner');
      expect(hits.single.prompt, 'line1\nline2');
    });

    test('"" 转义还原为单个双引号', () async {
      final svc = buildService({
        fakeCsvUrl: 'act,prompt\n"sayer","he said ""hi"" loudly"\n',
      });
      final hits = await svc.search('sayer');
      expect(hits.single.prompt, 'he said "hi" loudly');
    });

    test('行尾无换行的末条记录与残缺单列行均正确处理', () async {
      // 末条记录没有结束换行；中间夹一行只有单列（length<2 被丢弃）。
      final svc = buildService({
        fakeCsvUrl: 'act,prompt\n"solo"\n"tail","no trailing newline"',
      });
      final hits = await svc.search('tail');
      expect(hits, hasLength(1));
      expect(hits.single.title, 'tail');
      expect(hits.single.prompt, 'no trailing newline');
      // solo 只有一列，不可检索到
      final solo = await svc.search('solo');
      expect(solo, isEmpty);
    });

    test('全部源都拉不到数据时抛异常并留痕', () async {
      final svc = buildService({fakeCsvUrl: ''}, failingUrls: {fakeCsvUrl});
      await expectLater(svc.search('任意'), throwsException);
      expect(svc.lastError, isNotNull);
    });
  });

  group('JSON 解析（act/prompt 结构）', () {
    test('合法条目解码，act 去首尾空白，source 标注库名', () async {
      final svc = buildService({
        fakeJsonUrl: '[{"act":" Linux Guru ","prompt":"teaches linux"},'
            '{"act":"ok","prompt":"fine"}]',
      });
      final hits = await svc.search('linux');
      expect(hits, hasLength(1));
      expect(hits.single.title, 'Linux Guru');
      expect(hits.single.prompt, 'teaches linux');
      expect(hits.single.source, '源:$fakeJsonUrl');
    });

    test('act/prompt 非字符串的条目被静默过滤', () async {
      final svc = buildService({
        fakeJsonUrl: '[{"act":123,"prompt":"bad"},'
            '{"prompt":"no act"},'
            '{"act":"keeper","prompt":42}]',
      });
      final hits = await svc.search('keeper');
      expect(hits, isEmpty); // prompt 非字符串同样被过滤，无残留半成品
    });
  });

  group('多关键词评分与排序', () {
    const corpus = {
      fakeJsonUrl: '[{"act":"linux helper","prompt":"use the shell now"},'
          '{"act":"other","prompt":"linux and shell"},'
          '{"act":"third","prompt":"nothing relevant"}]',
    };

    test('标题命中权重（100）高于正文命中（10）', () async {
      final svc = buildService(corpus);
      // "linux" 在 A 的标题、B 的正文：A=100 > B=10
      final hits = await svc.search('linux');
      expect(hits.first.title, 'linux helper');
      expect(hits, hasLength(2)); // third 得分为 0 不入选
    });

    test('多关键词得分累计排序', () async {
      final svc = buildService(corpus);
      // A：标题命中 linux(100) + 正文命中 shell(10) = 110
      // B：正文命中 linux(10) + shell(10) = 20
      final hits = await svc.search('linux shell');
      expect(hits.map((h) => h.title).toList(), ['linux helper', 'other']);
    });

    test('空查询返回空列表且不触发拉取', () async {
      final svc = buildService(corpus, failingUrls: {fakeJsonUrl});
      // 若实现先拉取会因 failingUrls 抛异常，这里应直接短路
      expect(await svc.search('   '), isEmpty);
      expect(await svc.search(''), isEmpty);
    });

    test('limit 截断结果数', () async {
      final svc = buildService(corpus);
      final hits = await svc.search('linux shell', limit: 1);
      expect(hits, hasLength(1));
      expect(hits.single.title, 'linux helper');
    });

    test('跨源按 title（小写）去重，先出现的源优先', () async {
      final svc = buildService({
        fakeJsonUrl: '[{"act":"Coder","prompt":"from json"}]',
        fakeCsvUrl: 'act,prompt\n"coder","from csv"\n',
      });
      final hits = await svc.search('coder');
      expect(hits, hasLength(1));
      expect(hits.single.prompt, 'from json'); // json 源在 sources 里靠前
    });
  });
}
