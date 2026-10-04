import 'dart:convert';

import 'package:dio/dio.dart';

/// 一条技能搜索结果。
class SkillHit {
  const SkillHit({required this.title, required this.prompt, required this.source});

  /// 技能名（来源库的 act 字段）。
  final String title;

  /// 技能模板（完整提示词）。
  final String prompt;

  /// 来源库名称。
  final String source;
}

/// 一个远程技能库。
class SkillSource {
  const SkillSource({required this.name, required this.url, required this.format});

  final String name;

  /// 资源地址。默认源走 jsDelivr CDN（raw.githubusercontent 国内不稳定）。
  final String url;

  /// 'json'（[{act, prompt}]）或 'csv'（act,prompt 两列，带引号转义）。
  final String format;
}

/// 内置技能搜索源，按优先级排序——[kPrimarySkillSource] 是 AI
/// 查询技能时的默认首选源。
///
/// 选型依据：
/// - awesome-chatgpt-prompts-zh：124 条中文角色/任务提示词，中文场景命中率最高；
/// - awesome-chatgpt-prompts：官方英文库，150+ 条，中文库查不到时兜底；
/// - 两者都是静态 JSON/CSV，jsDelivr 镜像国内直连可用，无需鉴权。
const SkillSource kPrimarySkillSource = SkillSource(
  name: '中文技能库',
  url: 'https://cdn.jsdelivr.net/gh/PlexPt/awesome-chatgpt-prompts-zh@main/prompts-zh.json',
  format: 'json',
);

const SkillSource kFallbackSkillSource = SkillSource(
  name: '英文技能库',
  url: 'https://cdn.jsdelivr.net/gh/f/awesome-chatgpt-prompts@main/prompts.csv',
  format: 'csv',
);

const List<SkillSource> kDefaultSkillSources = [
  kPrimarySkillSource,
  kFallbackSkillSource,
];

/// 远程技能搜索服务：按 [sources] 顺序拉取技能库（带内存缓存），
/// 多关键词打分检索。模型通过 search_skills 工具使用；命中结果
/// 可由 install_skill 安装为快捷指令。
class SkillSearchService {
  SkillSearchService({
    Dio? dio,
    this.sources = kDefaultSkillSources,
    this.cacheTtl = const Duration(hours: 6),
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ));

  final Dio _dio;

  /// 搜索源优先级：越靠前越优先命中（AI 查询技能默认先查第一个）。
  final List<SkillSource> sources;

  /// 库列表缓存时长。技能库更新不频繁，6 小时足够新鲜且省流量。
  final Duration cacheTtl;

  List<SkillHit>? _cache;
  DateTime? _fetchedAt;
  String? _lastError;

  /// 最近一次拉取失败的说明（诊断用，供工具返回给模型）。
  String? get lastError => _lastError;

  /// 拉取全部源并合并（去重按 title）。单个源失败跳过；
  /// 全部失败时抛出，由调用方兜底。
  Future<List<SkillHit>> _fetchAll() async {
    if (_cache != null && _fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < cacheTtl) {
      return _cache!;
    }

    final hits = <SkillHit>[];
    final seen = <String>{};
    Object? lastErr;

    for (final src in sources) {
      try {
        final resp = await _dio.get<String>(
          src.url,
          options: Options(responseType: ResponseType.plain),
        );
        final parsed = src.format == 'json'
            ? _parseJson(resp.data ?? '', src.name)
            : _parseCsv(resp.data ?? '', src.name);
        for (final h in parsed) {
          final key = h.title.toLowerCase();
          if (key.isNotEmpty && seen.add(key)) hits.add(h);
        }
      } catch (e) {
        lastErr = e;
      }
    }

    // 仅当确实发生过拉取异常且无任何结果时才抛出；源正常返回但
    // 解析/过滤后为空是合法状态（如条目全部被静默过滤），返回空列表。
    if (hits.isEmpty && lastErr != null) {
      _lastError = '全部技能源拉取失败：$lastErr';
      throw Exception(_lastError);
    }

    _lastError = null;
    _cache = hits;
    _fetchedAt = DateTime.now();
    return hits;
  }

  List<SkillHit> _parseJson(String text, String sourceName) {
    final list = jsonDecode(text) as List<dynamic>;
    return [
      for (final item in list)
        if (item is Map && item['act'] is String && item['prompt'] is String)
          SkillHit(
            title: (item['act'] as String).trim(),
            prompt: item['prompt'] as String,
            source: sourceName,
          ),
    ];
  }

  List<SkillHit> _parseCsv(String text, String sourceName) {
    // 标准 CSV 状态机：处理引号包裹字段、字段内逗号/换行、"" 转义。
    // prompts.csv 的 prompt 列内含逗号与换行，按行 split 会截断内容。
    // 直接用 codeUnitAt 索引遍历：英文库有 5.7MB，先 runes.toList() 会
    // 额外物化约 40MB 的列表，手机上不值得；code unit 逐个写回 StringBuffer
    // 时代理对会按原顺序重组，非 BMP 字符（emoji 等）不受影响。
    final rows = <List<String>>[];
    final field = StringBuffer();
    var row = <String>[];
    var inQuotes = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (inQuotes) {
        if (c == 0x22) { // "
          if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x22) {
            field.writeCharCode(0x22);
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.writeCharCode(c);
        }
      } else if (c == 0x22) {
        inQuotes = true;
      } else if (c == 0x2C) { // ,
        row.add(field.toString());
        field.clear();
      } else if (c == 0x0A) { // \n
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
      } else if (c != 0x0D) { // \r（随 \n 一并处理）
        field.writeCharCode(c);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }

    final hits = <SkillHit>[];
    for (final r in rows) {
      if (r.length < 2) continue;
      final act = r[0].trim();
      if (act.isEmpty || act == 'act') continue; // 表头
      hits.add(SkillHit(title: act, prompt: r[1], source: sourceName));
    }
    return hits;
  }

  /// 多关键词检索：标题命中权重高于正文命中。空查询返回空列表。
  Future<List<SkillHit>> search(String query, {int limit = 8}) async {
    final keywords = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((k) => k.isNotEmpty)
        .toList();
    if (keywords.isEmpty) return const [];

    final all = await _fetchAll();
    final scored = <(SkillHit, int)>[];
    for (final h in all) {
      final title = h.title.toLowerCase();
      final prompt = h.prompt.toLowerCase();
      var score = 0;
      for (final k in keywords) {
        if (title.contains(k)) score += 100;
        if (prompt.contains(k)) score += 10;
      }
      if (score > 0) scored.add((h, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(limit).map((e) => e.$1).toList();
  }
}
