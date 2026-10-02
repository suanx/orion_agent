import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'memory_service.dart';
import 'rag_service.dart';
import 'terminal_service.dart';
import 'package:flutter/foundation.dart';

/// 工具基类：所有内置工具与 MCP 工具都实现此接口。
abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get parameters;

  Future<String> execute(Map<String, dynamic> args);
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…（已截断）';

String _stripTags(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
  const entities = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&nbsp;': ' ',
  };
  entities.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

/// 日期时间工具。
class DateTimeTool extends Tool {
  @override
  String get name => 'current_time';

  @override
  String get description => '获取当前日期时间。当用户询问时间、日期或需要时间上下文时调用。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final now = DateTime.now();
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    return '${now.year}年${now.month}月${now.day}日 星期${weekdays[now.weekday - 1]} $hh:$mm:$ss'
        '（设备本地时间，时区 UTC${now.timeZoneOffset.isNegative ? '-' : '+'}'
        '${now.timeZoneOffset.inHours}）';
  }
}

/// 计算器工具：递归下降解析器，支持 + - * / % ^ 与括号。
class CalculatorTool extends Tool {
  @override
  String get name => 'calculator';

  @override
  String get description => '精确计算数学表达式，支持加减乘除、取余、幂运算和括号。任何算术都应调用此工具而不是心算。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'expression': {'type': 'string', 'description': '数学表达式，如 (2+3)*4/5'},
        },
        'required': ['expression'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final expr = args['expression']?.toString() ?? '';
    if (expr.trim().isEmpty) return '错误：表达式为空';
    try {
      final value = _Parser(expr).parseWhole();
      return '$expr = $value';
    } catch (e) {
      return '错误：无法计算表达式 "$expr"（${e.toString().replaceFirst('Exception: ', '')}）';
    }
  }
}

class _Parser {
  _Parser(this.s);

  final String s;
  int _pos = 0;

  double parseWhole() {
    final v = _expr();
    _skip();
    if (_pos < s.length) throw Exception('存在无法解析的字符 "${s[_pos]}"');
    return v;
  }

  void _skip() {
    while (_pos < s.length && (s[_pos] == ' ' || s[_pos] == '\t')) {
      _pos++;
    }
  }

  bool _eat(String ch) {
    _skip();
    if (_pos < s.length && s[_pos] == ch) {
      _pos++;
      return true;
    }
    return false;
  }

  double _expr() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        v += _term();
      } else if (_eat('-')) {
        v -= _term();
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _power();
    while (true) {
      if (_eat('*')) {
        v *= _power();
      } else if (_eat('/')) {
        final d = _power();
        if (d == 0) throw Exception('除以零');
        v /= d;
      } else if (_eat('%')) {
        final d = _power();
        if (d == 0) throw Exception('对零取余');
        v %= d;
      } else {
        return v;
      }
    }
  }

  double _power() {
    // 右结合：2^3^2 = 2^(3^2)
    final base = _unary();
    if (_eat('^')) return math.pow(base, _power()).toDouble();
    return base;
  }

  double _unary() {
    _skip();
    if (_pos < s.length && s[_pos] == '-') {
      _pos++;
      return -_unary();
    }
    if (_pos < s.length && s[_pos] == '+') {
      _pos++;
      return _unary();
    }
    return _primary();
  }

  double _primary() {
    _skip();
    if (_pos < s.length && s[_pos] == '(') {
      _pos++;
      final v = _expr();
      if (!_eat(')')) throw Exception('缺少右括号');
      return v;
    }
    final start = _pos;
    while (_pos < s.length &&
        (RegExp(r'[0-9.]').hasMatch(s[_pos]))) {
      _pos++;
    }
    if (_pos == start) {
      throw Exception('位置 $_pos 处缺少数字');
    }
    return double.parse(s.substring(start, _pos));
  }
}

/// 网页抓取工具。
class WebFetchTool extends Tool {
  WebFetchTool(this._dio);

  final Dio _dio;

  @override
  String get name => 'web_fetch';

  @override
  String get description => '抓取指定 URL 的网页内容并转为纯文本。用于读取用户给定的链接或搜索到的网页。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '完整的网页地址，以 http:// 或 https:// 开头'},
        },
        'required': ['url'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final url = args['url']?.toString() ?? '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return '错误：url 必须以 http:// 或 https:// 开头';
    }
    try {
      final resp = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
          },
        ),
      );
      final text = _stripTags(resp.data ?? '');
      if (text.isEmpty) return '错误：页面内容为空或无法提取文本';
      return _truncate(text, 4000);
    } on DioException catch (e) {
      return '错误：抓取失败（${e.response?.statusCode ?? e.message}）';
    }
  }
}

/// 联网搜索工具（DuckDuckGo HTML 版，无需 API Key）。
class WebSearchTool extends Tool {
  WebSearchTool(this._dio);

  final Dio _dio;

  @override
  String get name => 'web_search';

  @override
  String get description => '联网搜索。当需要实时信息、新闻、事实查询时调用。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '搜索关键词'},
        },
        'required': ['query'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final query = args['query']?.toString() ?? '';
    if (query.trim().isEmpty) return '错误：搜索词为空';
    try {
      final resp = await _dio.get<String>(
        'https://html.duckduckgo.com/html/',
        queryParameters: {'q': query},
        options: Options(
          responseType: ResponseType.plain,
          headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
        ),
      );
      final html = resp.data ?? '';
      final titles = RegExp(
        r'class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
      ).allMatches(html).toList();
      final snippets = RegExp(
        r'class="result__snippet"[^>]*>([\s\S]*?)</a>',
      ).allMatches(html).toList();

      if (titles.isEmpty) return '错误：没有搜索到结果，或搜索服务暂时不可用。';

      final buf = StringBuffer();
      for (var i = 0; i < titles.length && i < 5; i++) {
        var href = titles[i].group(1) ?? '';
        // DDG 链接是重定向形式 //duckduckgo.com/l/?uddg=<encoded>
        final uddg = RegExp(r'uddg=([^&]+)').firstMatch(href)?.group(1);
        if (uddg != null) href = Uri.decodeComponent(uddg);
        final title = _stripTags(titles[i].group(2) ?? '');
        final snippet = i < snippets.length ? _stripTags(snippets[i].group(1) ?? '') : '';
        buf.writeln('${i + 1}. $title');
        if (href.isNotEmpty) buf.writeln('   链接: $href');
        if (snippet.isNotEmpty) buf.writeln('   摘要: $snippet');
        buf.writeln();
      }
      return _truncate(buf.toString(), 4000);
    } on DioException catch (e) {
      return '错误：搜索失败（${e.response?.statusCode ?? e.message}），可建议用户稍后重试。';
    }
  }
}

/// 长期记忆工具。
class SaveMemoryTool extends Tool {
  SaveMemoryTool(this._memory);

  final MemoryService _memory;

  @override
  String get name => 'save_memory';

  @override
  String get description =>
      '把用户的长期信息（偏好、背景、重要事实）保存到长期记忆，供以后的对话使用。只在用户透露值得长期记住的信息时调用。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'content': {'type': 'string', 'description': '要记住的信息，一句话概括'},
        },
        'required': ['content'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final text = args['content']?.toString() ?? '';
    if (text.trim().isEmpty) return '错误：内容为空';
    await _memory.addNote(text.trim());
    debugPrint('memory saved: $text');
    return '已保存到长期记忆';
  }
}

/// 知识库检索工具。
class SearchKnowledgeTool extends Tool {
  SearchKnowledgeTool(this._rag, this._embed);

  final RagService _rag;
  final BatchEmbed _embed;

  @override
  String get name => 'search_knowledge';

  @override
  String get description =>
      '在用户的知识库（其导入的文档与笔记）中检索相关资料。当用户的问题可能与其导入的文档内容有关，或用户要求"查我资料/查知识库"时调用。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '检索查询语句'},
        },
        'required': ['query'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final query = args['query']?.toString() ?? '';
    if (query.trim().isEmpty) return '错误：检索词为空';
    final hits = await _rag.search(
      query: query,
      embedOne: (q) async => (await _embed([q])).first,
    );
    if (hits.isEmpty) return '知识库中没有找到相关内容。';
    final buf = StringBuffer();
    for (var i = 0; i < hits.length; i++) {
      buf.writeln('【资料${i + 1}｜来源: ${hits[i].docTitle}】');
      buf.writeln(hits[i].content);
      buf.writeln();
    }
    return _truncate(buf.toString(), 4000);
  }
}

/// 终端环境命令执行工具（Alpine + proot 沙箱）。
class RunCommandTool extends Tool {
  RunCommandTool(this._terminal);

  final TerminalService _terminal;

  @override
  String get name => 'run_command';

  @override
  String get description =>
      '在应用内置的 Alpine Linux 环境中执行 shell 命令并返回输出。可用于文件处理、'
      '运行脚本、安装软件包（apk add，已配置国内镜像）等。环境未安装时会提示先安装。'
      '注意：命令在沙箱内运行，仅能访问应用目录与系统基础挂载。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'command': {'type': 'string', 'description': '要执行的 shell 命令'},
        },
        'required': ['command'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final command = args['command']?.toString() ?? '';
    if (command.trim().isEmpty) return '错误：命令为空';
    if (!await _terminal.isInstalled()) {
      return '错误：终端环境尚未安装。请提示用户到「我的 → 终端环境」中一键安装 Alpine 环境。';
    }
    try {
      final r = await _terminal.run(command);
      final output = r.output.trim().isEmpty ? '（无输出）' : _truncate(r.output.trim(), 4000);
      return '退出码 ${r.exitCode}\n$output';
    } catch (e) {
      return '错误：命令执行失败（$e）';
    }
  }
}

/// 工具注册表：统一管理内置工具与（未来的）MCP 工具。
class ToolRegistry {
  ToolRegistry({
    required MemoryService memoryService,
    RagService? ragService,
    BatchEmbed? batchEmbed,
    TerminalService? terminalService,
  }) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
    ));
    _tools = [
      DateTimeTool(),
      CalculatorTool(),
      WebSearchTool(dio),
      WebFetchTool(dio),
      SaveMemoryTool(memoryService),
      if (ragService != null && batchEmbed != null)
        SearchKnowledgeTool(ragService, batchEmbed),
      if (terminalService != null) RunCommandTool(terminalService),
    ];
  }

  late final List<Tool> _tools;

  List<Tool> get all => List.unmodifiable(_tools);

  /// 注册工具；同名工具（如 MCP 重复连接）不会重复注册。
  void register(Tool tool) {
    if (!_tools.any((t) => t.name == tool.name)) {
      _tools.add(tool);
    }
  }

  /// 转成 OpenAI tools 参数格式。
  List<Map<String, dynamic>> toOpenAiTools() => _tools
      .map((t) => {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
          })
      .toList();

  /// 执行一次工具调用，永不抛异常（错误转为文本返回给模型）。
  Future<String> execute(String name, String rawArguments) async {
    final tool = _tools.where((t) => t.name == name).toList();
    if (tool.isEmpty) return '错误：未找到名为 "$name" 的工具';
    Map<String, dynamic> args;
    try {
      final decoded = rawArguments.trim().isEmpty ? {} : jsonDecode(rawArguments);
      if (decoded is Map<String, dynamic>) {
        args = decoded;
      } else {
        args = {};
      }
    } catch (e) {
      return '错误：参数不是合法 JSON（$e）';
    }
    try {
      return await tool.first.execute(args);
    } catch (e) {
      return '错误：工具执行失败（$e）';
    }
  }
}
