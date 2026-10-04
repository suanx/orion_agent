import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'package:characters/characters.dart';

import 'memory_service.dart';
import 'rag_service.dart';
import 'skill_search_service.dart';
import 'skill_service.dart';
import 'terminal_service.dart';
import 'package:flutter/foundation.dart';

/// 工具基类：所有内置工具与 MCP 工具都实现此接口。
abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get parameters;

  Future<String> execute(Map<String, dynamic> args);
}

/// 按字素簇安全截断。
/// String.length 统计的是 UTF-16 code unit，直接 substring(0, max) 会把代理对
/// （emoji 如 😀 = U+D83D U+DE00、扩展汉字如 𠮷）劈开，产生孤立代理项。
/// Dart 在 jsonEncode / utf8.encode 时会把孤立代理项静默替换为 U+FFFD，
/// 于是知识库与回答里的 emoji 变成"�"——不报错，只是内容被悄悄改坏。
String _truncate(String s, int max) {
  if (max <= 0) return s;
  if (s.characters.length <= max) return s;
  return '${s.characters.take(max).toString()}…（已截断）';
}

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
    // Duration.inHours 对非整小时偏移做截断：Asia/Kolkata(+05:30) 会输出 UTC+5，
    // America/St_Johns(-03:30) 会输出 UTC-3。错误的时区会让模型算错跨时区时间。
    final off = now.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final abs = off.abs();
    final tz = off.inMinutes % 60 == 0
        ? 'UTC$sign${abs.inHours}'
        : 'UTC$sign${abs.inHours}:${(abs.inMinutes % 60).toString().padLeft(2, '0')}';
    return '${now.year}年${now.month}月${now.day}日 '
        '星期${weekdays[now.weekday - 1]} $hh:$mm:$ss'
        '（设备本地时间，时区 $tz）';
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
      // math.pow 在实数域无定义时返回 NaN（负数的非整数次幂），除以极小数返回
      // Infinity。这些都不是异常，会被原样拼进结果字符串，于是 Agent 把
      // "(-8)^0.33 = NaN" 当成正确答案复述给用户。必须显式拦掉。
      if (value.isNaN) {
        return '错误：表达式 "$expr" 在实数域无定义（如负数的非整数次幂）';
      }
      if (value.isInfinite) {
        return '错误：表达式 "$expr" 结果溢出（除数过小或幂过大）';
      }
      return '$expr = ${_fmtNum(value)}';
    } catch (e) {
      return '错误：无法计算表达式 "$expr"（${e.toString().replaceFirst('Exception: ', '')}）';
    }
  }

  /// 格式化计算结果。全程 double 直接 toString 会输出 "2.0"、"0.30000000000000004"，
  /// 与工具 description 承诺的「精确计算」不符，也让用户怀疑结果可信度。
  static String _fmtNum(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    var s = v.toStringAsPrecision(15);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    // toStringAsPrecision 可能产出科学计数法（1e+20），转成可读形式
    final exp = RegExp(r'^([+-]?[\d.]+)e([+-]?\d+)$').firstMatch(s);
    if (exp != null) {
      final mant = double.parse(exp.group(1)!);
      final exp10 = int.parse(exp.group(2)!);
      return '${mant.toStringAsFixed((exp10 - 1).clamp(0, 20))}e$exp10';
    }
    return s;
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
    var v = _unary();
    while (true) {
      if (_eat('*')) {
        v *= _unary();
      } else if (_eat('/')) {
        final d = _unary();
        if (d == 0) throw Exception('除以零');
        v /= d;
      } else if (_eat('%')) {
        final d = _unary();
        if (d == 0) throw Exception('对零取余');
        v %= d;
      } else {
        return v;
      }
    }
  }

  /// 一元负号优先级【高于】幂运算：标准数学约定 -2^2 = -(2^2) = -4。
  /// 原来 _power 先调 _unary，负号被贪婪吃掉，等价于强制 (-2)^2 = 4。
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
    return _power();
  }

  double _power() {
    // 右结合：2^3^2 = 2^(3^2)。指数取 _unary 以支持 2^-3。
    final base = _primary();
    if (_eat('^')) return math.pow(base, _unary()).toDouble();
    return base;
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
      // title 与 snippet 必须按【出现位置】配对。原来用两条独立正则分别 allMatches、
      // 再按下标 i 配对，一旦某条结果没有摘要（或 snippet 内含嵌套 </a> 导致跨条
      // 吞并），摘要就会被安到错误的标题上，Agent 引用错误"事实"作答。
      // 这里改为：按顺序取每个标题，再取它【之后最近的那条】摘要，天然对齐。
      final aRe = RegExp(
        r'<a\b([^>]*\bclass="[^"]*\bresult__a\b[^"]*"[^>]*)>([\s\S]*?)</a>',
        caseSensitive: false,
      );
      final snipRe = RegExp(
        r'<a\b[^>]*\bclass="[^"]*\bresult__snippet\b[^"]*"[^>]*>([\s\S]*?)</a>',
        caseSensitive: false,
      );
      final titles = aRe.allMatches(html).toList();

      if (titles.isEmpty) {
        // 区分"确实没有结果"与"页面结构变了 / 被反爬拦截"：后者若也报"没有结果"，
        // 会让 Agent 与用户一起误判，且不留任何排查线索。
        final blocked = html.contains('anomaly') ||
            html.contains('Unfortunately') ||
            html.contains('captcha') ||
            html.contains('blocked');
        return blocked
            ? '错误：搜索服务拒绝了本次请求（可能触发反爬拦截），请稍后重试或换个说法。'
            : '错误：没有搜索到结果，请换个关键词。';
      }

      final buf = StringBuffer();
      var used = 0;
      for (var i = 0; i < titles.length && used < 5; i++) {
        final t = titles[i];
        final title = _stripTags(t.group(2) ?? '');
        if (title.isEmpty) continue;

        // 摘要必须属于【当前这条】结果，所以搜索范围要截到下一条标题为止。
        // 否则本条没有摘要时会去"借用"下一条的摘要——这正是原 bug 的错位，
        // 只是从"按下标配对"换成"向后贪心"，错位依旧。
        final limit = (i + 1 < titles.length) ? titles[i + 1].start : html.length;
        final tail = html.substring(t.end, limit);
        final m = snipRe.firstMatch(tail);
        final snippet = (m != null && m.start < 4000) ? _stripTags(m.group(1) ?? '') : '';

        // DDG 链接是重定向形式 //duckduckgo.com/l/?uddg=<encoded>
        var href = RegExp(r'href="([^"]*)"').firstMatch(t.group(1) ?? '')?.group(1) ?? '';
        final uddg = RegExp(r'uddg=([^&]+)').firstMatch(href)?.group(1);
        if (uddg != null) href = Uri.decodeComponent(uddg);

        buf.writeln('${used + 1}. $title');
        if (href.startsWith('http')) buf.writeln('   链接: $href');
        if (snippet.isNotEmpty) buf.writeln('   摘要: $snippet');
        buf.writeln();
        used++;
      }
      if (buf.isEmpty) return '错误：搜索结果解析后为空，请换个关键词。';
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
      // embedding 服务可能返回空数组，直接 .first 会抛 StateError；
      // 这里给一个兜底，让检索空手而归而不是让整个 Agent 回合崩掉。
      embedOne: (q) async {
        final vecs = await _embed([q]);
        if (vecs.isEmpty) return const <double>[];
        return vecs.first;
      },
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
      '在应用内置的 Linux 环境（Alpine/Debian，proot 沙箱）中执行 shell 命令并返回输出。'
      '可用于文件处理、运行脚本、安装软件包（apk/apt，已配置国内镜像）等。'
      '环境未安装时会提示先安装。注意：命令在沙箱内运行，仅能访问应用目录与系统基础挂载。';

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
    // 必须把【检查过的那个】distro 显式传给 runOn。activeDistro 是可变字段，
    // 若这里调 run()（内部再读一次 activeDistro），用户若在另一页切换了发行版，
    // 就会在未初始化的文件系统上执行命令，行为不可预期。
    final distro = _terminal.activeDistro;
    if (!await _terminal.isInstalled(distro)) {
      return '错误：当前终端环境（${distro.name}）尚未安装。'
          '请提示用户到「我的 → 终端环境」中选择发行版并一键安装。';
    }
    try {
      final r = await _terminal.runOn(distro, command);
      final output =
          r.output.trim().isEmpty ? '（无输出）' : _truncate(r.output.trim(), 4000);
      return '退出码 ${r.exitCode}\n$output';
    } catch (e) {
      return '错误：命令执行失败（$e）';
    }
  }
}

/// 技能调用工具：把用户安装的快捷指令模板展开返回给模型照做。
/// 技能本质是提示词模板而非代码，模型拿到模板后按其中的步骤执行任务。
class UseSkillTool extends Tool {
  UseSkillTool(this._skills);

  final SkillService _skills;

  @override
  String get name => 'use_skill';

  @override
  String get description =>
      '获取用户安装的快捷指令技能（如 写周报、今日要闻、专题调研等）的完整执行指令。'
      '当用户的请求与某个技能的用途匹配，或用户输入「/技能名」时调用本工具，'
      '然后严格按返回的指令步骤执行任务。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '技能名称，需与已安装的技能名完全一致'},
          'input': {'type': 'string', 'description': '用户本次请求的具体内容（作为技能的输入参数），可为空'},
        },
        'required': ['name'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final name = args['name']?.toString().trim() ?? '';
    final input = args['input']?.toString() ?? '';
    if (name.isEmpty) return '错误：技能名为空';
    await _skills.load();
    final skill = _skills.findByName(name);
    if (skill == null) {
      final names = _skills.skills.map((s) => s.name).toList();
      return '错误：没有名为「$name」的技能。'
          '当前已安装：${names.isEmpty ? '（无）' : names.join('、')}';
    }
    return '请严格按以下技能指令执行任务：\n${SkillService.expand(skill, input)}';
  }
}

/// 技能搜索工具：在内置技能库中检索新技能。
/// 默认优先查中文技能库（kPrimarySkillSource），查不到再查英文兜底库。
class SearchSkillsTool extends Tool {
  SearchSkillsTool(this._search);

  final SkillSearchService _search;

  @override
  String get name => 'search_skills';

  @override
  String get description =>
      '在技能库中搜索用户还没有的技能/角色提示词（如「我想找一个做 PPT 的技能」）。'
      '默认优先搜索内置中文技能库，未命中时自动扩展到英文技能库。'
      '找到合适的技能后，向用户确认再用 install_skill 安装为快捷指令。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '搜索关键词，可多个（空格分隔），如「写作 面试」',
          },
        },
        'required': ['query'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final query = args['query']?.toString().trim() ?? '';
    if (query.isEmpty) return '错误：搜索词为空';
    try {
      final hits = await _search.search(query);
      if (hits.isEmpty) {
        return '技能库中没有与「$query」相关的技能。'
            '可以换个关键词再试，或建议用户在技能页手动创建。';
      }
      final buf = StringBuffer()
        ..writeln('找到 ${hits.length} 条技能（来自：${hits.first.source}）：');
      for (var i = 0; i < hits.length; i++) {
        final h = hits[i];
        final brief = h.prompt.length > 160 ? '${h.prompt.substring(0, 160)}…' : h.prompt;
        buf
          ..writeln('${i + 1}. ${h.title}')
          ..writeln('   模板预览: ${brief.replaceAll(RegExp(r'\s+'), ' ')}')
          ..writeln();
      }
      buf.write('用户确认后，用 install_skill 工具（传技能名与完整模板）安装，'
          '安装后即可用「/技能名」或 use_skill 调用。');
      return buf.toString();
    } catch (e) {
      return '错误：技能库拉取失败（${_search.lastError ?? e}）。'
          '可建议用户检查网络后重试。';
    }
  }
}

/// 技能安装工具：把搜索到的技能落库为快捷指令（与手动安装等价）。
class InstallSkillTool extends Tool {
  InstallSkillTool(this._skills);

  final SkillService _skills;

  @override
  String get name => 'install_skill';

  @override
  String get description =>
      '把一个技能安装为用户的快捷指令（之后用「/技能名」触发或 use_skill 调用）。'
      '技能名与模板通常来自 search_skills 的搜索结果；安装前必须先向用户确认。'
      '不要安装用户没有要求保存的内容。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '技能名称（将作为 /指令名），尽量简短'},
          'template': {'type': 'string', 'description': '完整技能模板（提示词），可包含 {input} 占位符接收调用参数'},
        },
        'required': ['name', 'template'],
      };

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final name = args['name']?.toString().trim() ?? '';
    final template = args['template']?.toString() ?? '';
    if (name.isEmpty) return '错误：技能名为空';
    if (template.trim().isEmpty) return '错误：模板为空';
    if (name.startsWith('/')) return '错误：技能名不要带「/」前缀，直接写名字即可';
    await _skills.load();
    if (_skills.findByName(name) != null) {
      return '已存在同名技能「$name」，未重复安装。可用其他名字，或提示用户到技能页管理。';
    }
    await _skills.addSkill(name, template);
    return '技能「$name」已安装，用户输入「/$name」即可触发。';
  }
}

/// Agent 权限模式（聊天状态条的「权限」选择）。
///
/// 三档由松到紧：完全访问 > 工作区读写 > 只读。
/// 作用于两处：[ToolRegistry.toOpenAiTools] 只向模型暴露允许的工具，
/// [ToolRegistry.execute] 对越权调用直接拒绝（双保险：模型幻觉调用
/// 未暴露的工具时也能拦住）。
enum AgentPermission { readOnly, workspace, full }

extension AgentPermissionX on AgentPermission {
  String get label => switch (this) {
        AgentPermission.readOnly => '只读',
        AgentPermission.workspace => '工作区读写',
        AgentPermission.full => '完全访问',
      };

  String get desc => switch (this) {
        AgentPermission.readOnly =>
          '仅可联网搜索、读取网页、计算与查询知识库',
        AgentPermission.workspace =>
          '另可保存记忆、在终端环境执行命令（文件活动约定在 workspace）',
        AgentPermission.full => '内置全部工具，以及 MCP 扩展工具',
      };

  /// 只读档可用的内置工具白名单。
  static const _readOnlyTools = <String>{
    'current_time', 'calculator', 'web_search', 'web_fetch', 'search_knowledge',
    'use_skill', 'search_skills',
  };

  /// 工作区读写档 = 只读 + 记忆写入 + 终端命令 + 技能安装。
  static const _workspaceTools = <String>{
    ..._readOnlyTools,
    'save_memory', 'run_command', 'install_skill',
  };

  /// 是否允许使用 [toolName]。内置名单之外的名字（MCP 扩展工具）
  /// 仅在「完全访问」档放行。
  bool allows(String toolName) {
    switch (this) {
      case AgentPermission.readOnly:
        return _readOnlyTools.contains(toolName);
      case AgentPermission.workspace:
        return _workspaceTools.contains(toolName);
      case AgentPermission.full:
        return true;
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
    SkillService? skillService,
    SkillSearchService? skillSearchService,
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
      if (skillService != null) UseSkillTool(skillService),
      if (skillSearchService != null) SearchSkillsTool(skillSearchService),
      if (skillService != null) InstallSkillTool(skillService),
    ];
  }

  late final List<Tool> _tools;

  /// 当前权限模式。由聊天页的「权限」选择联动设置（chatProvider），
  /// 默认工作区读写（Agent 可写记忆与终端，MCP 扩展工具需手动放开）。
  AgentPermission permission = AgentPermission.workspace;

  List<Tool> get all => List.unmodifiable(_tools);

  /// 注册工具；同名工具（如 MCP 重复连接）不会重复注册。
  void register(Tool tool) {
    if (!_tools.any((t) => t.name == tool.name)) {
      _tools.add(tool);
    }
  }

  /// 注销名字以 [prefix] 开头的所有工具。
  ///
  /// MCP 必需：register() 对同名工具直接跳过，所以没有这个方法时，
  /// 「重连」会保留所有旧 McpTool（持有旧 client / 旧 Dio），新连接被丢弃；
  /// 「停用 / 删除服务器」后工具也不会消失，Agent 继续调用已停用的端点。
  void unregisterPrefix(String prefix) {
    _tools.removeWhere((t) => t.name.startsWith(prefix));
  }

  /// 当前已注册的工具名（供测试与调试）。
  List<String> get toolNames => _tools.map((t) => t.name).toList();

  /// 转成 OpenAI tools 参数格式。只暴露当前权限允许的工具——
  /// 模型看不到被禁用的工具，从源头减少越权调用。
  List<Map<String, dynamic>> toOpenAiTools() => _tools
      .where((t) => permission.allows(t.name))
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
    // 双保险：即使模型幻觉调用了未暴露的工具，这里也直接拒绝。
    if (!permission.allows(name)) {
      return '错误：当前权限为「${permission.label}」，不允许使用工具 "$name"。'
          '如需使用，请在聊天页的权限选择中切换模式。';
    }
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
