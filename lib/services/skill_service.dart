import 'package:drift/drift.dart';

import 'database.dart';

/// 内置技能模板（可一键安装为快捷指令）。
///
/// [key] 仅用于判断是否已安装（不落库），[name] 落库为指令名，
/// [template] 中的 `{input}` 会被聊天里的参数替换。
class BuiltinSkill {
  const BuiltinSkill({
    required this.key,
    required this.emoji,
    required this.name,
    required this.summary,
    required this.template,
    required this.category,
    this.needsTerminal = false,
  });

  final String key;
  final String emoji;
  final String name;
  final String summary;
  final String template;
  final String category;

  /// 依赖内置 Linux 终端环境（未安装时安装会给出提示）。
  final bool needsTerminal;
}

/// 内置技能库。模板面向手机端 Agent 的实际能力（联网搜索/网页抓取/
/// 计算/记忆/知识库/终端），不依赖外部服务。
const List<BuiltinSkill> builtinSkills = [
  // ---------------- 写作办公 ----------------
  BuiltinSkill(
    key: 'weekly_report',
    emoji: '📝',
    name: '写周报',
    summary: '把零散工作内容整理成结构化周报',
    category: '写作办公',
    template: '帮我把下面的工作内容整理成一份周报，要求：\n'
        '1. 按「本周完成 / 进行中 / 下周计划 / 风险与需要的支持」四段组织；\n'
        '2. 每条用「动作 + 结果 + 数据」的格式，尽量量化，避免空话；\n'
        '3. 语言简洁专业，不要写客套话；\n'
        '4. 最后用一句话总结本周整体进展。\n\n'
        '原始内容：\n{input}',
  ),
  BuiltinSkill(
    key: 'polish_text',
    emoji: '✨',
    name: '润色文字',
    summary: '改通顺、去啰嗦，保留原意',
    category: '写作办公',
    template: '请润色下面这段文字：\n'
        '1. 修正语病、错别字和标点；\n'
        '2. 删掉冗余表达，让句子更简洁；\n'
        '3. 保持原意和信息量不变，不要添加原文没有的内容；\n'
        '4. 语气保持自然，不要变成生硬的公文腔。\n\n'
        '先给出改写后的版本，再用一句话说明主要改了什么。\n\n'
        '原文：\n{input}',
  ),
  BuiltinSkill(
    key: 'summarize',
    emoji: '📌',
    name: '总结归纳',
    summary: '长文压缩成要点，带层次',
    category: '写作办公',
    template: '请总结下面的内容，要求：\n'
        '1. 先用一句话概括核心结论；\n'
        '2. 再分点列出关键信息（不超过 6 条），每条尽量短；\n'
        '3. 如果涉及数字、时间、金额、人名，必须保留准确；\n'
        '4. 原文没提到的信息不要补充。\n\n'
        '内容：\n{input}',
  ),
  BuiltinSkill(
    key: 'translate',
    emoji: '🌏',
    name: '翻译',
    summary: '中英互译，给地道表达',
    category: '写作办公',
    template: '请翻译下面的内容：\n'
        '1. 中文译成英文，英文译成中文；\n'
        '2. 追求地道自然，不要逐字硬译；\n'
        '3. 专业术语给出通用译法，必要时在括号里附上原词；\n'
        '4. 先给译文，如果有关键的用词选择或歧义，再用一两句说明。\n\n'
        '内容：\n{input}',
  ),
  BuiltinSkill(
    key: 'email_reply',
    emoji: '✉️',
    name: '回邮件',
    summary: '根据要点拟一封得体的回复',
    category: '写作办公',
    template: '帮我写一封回复邮件。请根据下面的背景和我的要点，'
        '起草一封语气得体、条理清晰的回复：\n'
        '1. 开头简要回应对方关切，不要复述对方原文；\n'
        '2. 正文分点说明，每点一句话；\n'
        '3. 结尾给出明确的下一步或时间预期；\n'
        '4. 长度控制在 200 字以内，不要过度客套。\n\n'
        '背景与要点：\n{input}',
  ),
  BuiltinSkill(
    key: 'extract_todo',
    emoji: '✅',
    name: '提取待办',
    summary: '从杂乱记录里抽出可执行清单',
    category: '写作办公',
    template: '从下面的内容里提取所有可以执行的待办事项：\n'
        '1. 每条写成「做什么 · 什么时候 · 谁负责」的格式；\n'
        '2. 没有明确时间的标为「时间待定」，不要自己编时间；\n'
        '3. 信息不全的地方用「?」标出，提醒我补充；\n'
        '4. 按紧急程度排序。\n\n'
        '内容：\n{input}',
  ),

  // ---------------- 信息检索 ----------------
  BuiltinSkill(
    key: 'daily_news',
    emoji: '📰',
    name: '今日要闻',
    summary: '联网搜集今天的重要新闻',
    category: '信息检索',
    template: '请联网搜索今天的重要新闻并汇总：\n'
        '1. 先用 web_search 检索，必要时用 web_fetch 读取正文；\n'
        '2. 挑 5 条真正重要的，每条用「标题 + 一句话说明 + 来源链接」；\n'
        '3. 按重要性排序，不要凑数；\n'
        '4. 注意区分事实与观点。\n\n'
        '关注方向（可留空表示不限）：{input}',
  ),
  BuiltinSkill(
    key: 'read_link',
    emoji: '🔗',
    name: '读链接总结',
    summary: '抓取网页正文并提炼重点',
    category: '信息检索',
    template: '请用 web_fetch 读取我给的链接，然后：\n'
        '1. 先用一句话说明这个页面是什么；\n'
        '2. 提炼 3~6 条核心信息；\n'
        '3. 如果有具体数据、结论、时间点，务必保留；\n'
        '4. 最后告诉我这个页面值不值得细看，为什么。\n\n'
        '链接：{input}',
  ),
  BuiltinSkill(
    key: 'research_topic',
    emoji: '🔬',
    name: '专题调研',
    summary: '多轮检索后给出结构化调研结论',
    category: '信息检索',
    template: '请对下面的主题做一次调研：\n'
        '1. 先用 web_search 至少检索 2~3 个不同角度的关键词；\n'
        '2. 用 web_fetch 打开其中最相关的 2~3 篇读正文；\n'
        '3. 输出结构：背景 → 现状与关键事实 → 主要分歧 → 结论；\n'
        '4. 每条关键事实标注来源链接，找不到出处的宁可不写；\n'
        '5. 最后列出还有哪些问题没能查清。\n\n'
        '主题：{input}',
  ),
  BuiltinSkill(
    key: 'compare_options',
    emoji: '⚖️',
    name: '对比选型',
    summary: '对多个选项做维度化对比',
    category: '信息检索',
    template: '帮我对比下面这些选项，辅助我做决定：\n'
        '1. 先列出对比维度（结合我给的用途来定，不要套模板）；\n'
        '2. 用 Markdown 表格逐项对比；\n'
        '3. 需要实时信息或价格、参数时，先联网检索确认；\n'
        '4. 最后给出推荐，并说明推荐前提（什么情况下推荐会变）。\n\n'
        '要对比的选项与我的用途：\n{input}',
  ),

  // ---------------- 生活助手 ----------------
  BuiltinSkill(
    key: 'trip_plan',
    emoji: '🧳',
    name: '做行程规划',
    summary: '按天排出可执行的旅行安排',
    category: '生活助手',
    template: '帮我规划一次旅行行程：\n'
        '1. 按天排，每天分上午/下午/晚上，标出地点与大致耗时；\n'
        '2. 相邻景点就近安排，减少来回折腾；\n'
        '3. 穿插吃饭和休息时间，强度别排太满；\n'
        '4. 需要查天气、门票、开放时间时先联网确认；\n'
        '5. 最后给 3 条实用提醒。\n\n'
        '目的地、天数、预算、同行人：\n{input}',
  ),
  BuiltinSkill(
    key: 'budget_plan',
    emoji: '💰',
    name: '记账算账',
    summary: '整理收支并算出结果',
    category: '生活助手',
    template: '帮我整理下面的账目：\n'
        '1. 先分「收入 / 支出」归类，支出再按类别汇总；\n'
        '2. 涉及金额加减、分摊、占比的，必须用 calculator 精确计算，不要心算；\n'
        '3. 输出总额、分类小计和结余；\n'
        '4. 如果发现明显不合理的支出或者占比异常，指出来。\n\n'
        '账目：\n{input}',
  ),
  BuiltinSkill(
    key: 'check_doc',
    emoji: '🔎',
    name: '查我的资料',
    summary: '在自己的知识库里检索并回答',
    category: '生活助手',
    template: '请用 search_knowledge 在我的知识库里检索并回答下面这个问题：\n'
        '1. 先用我问题的原意检索，效果不好就换几个近义关键词再试；\n'
        '2. 回答必须基于检索到的资料，并注明来源（如「来源：资料1」）；\n'
        '3. 资料里没有的内容明确说「资料中没有提到」，不要编造；\n'
        '4. 最后列出你引用了哪几份资料。\n\n'
        '问题：{input}',
  ),
  BuiltinSkill(
    key: 'remember_me',
    emoji: '🧠',
    name: '记住这件事',
    summary: '把重要信息存进长期记忆',
    category: '生活助手',
    template: '请把下面这条信息用 save_memory 存进长期记忆：\n'
        '1. 先把它压缩成一句准确、无歧义的话（保留关键数字和名称）；\n'
        '2. 不要加入我原文没有的推测；\n'
        '3. 存完后告诉我你记了什么，让我确认。\n\n'
        '要记住的信息：\n{input}',
  ),

  // ---------------- 开发者工具 ----------------
  BuiltinSkill(
    key: 'run_code',
    emoji: '⌨️',
    name: '跑代码',
    summary: '在沙箱里执行脚本并解释结果',
    category: '开发者工具',
    needsTerminal: true,
    template: '请在内置 Linux 终端环境里完成任务：\n'
        '1. 用 run_command 执行必要的命令，一次只做一件事；\n'
        '2. 涉及文件时放在 /workspace 目录下，方便我之后取用；\n'
        '3. 如果某个命令报错，先读报错再决定怎么改，不要重复试同一个命令；\n'
        '4. 结束后把「做了什么、结果如何、产物在哪」讲清楚。\n\n'
        '任务：{input}',
  ),
  BuiltinSkill(
    key: 'explain_code',
    emoji: '🧩',
    name: '解释报错',
    summary: '读懂报错并给出可执行修法',
    category: '开发者工具',
    template: '帮我分析这个报错：\n'
        '1. 先用一两句说明报错的直接原因（哪一行、哪个值不对）；\n'
        '2. 再说明根本原因，必要时指出涉及的机制；\n'
        '3. 给出最小改动的修复方案，附带修改后的代码片段；\n'
        '4. 如果信息不足无法定位，明确告诉我还需要什么（完整堆栈、复现步骤等），不要瞎猜。\n\n'
        '报错与相关代码：\n{input}',
  ),
  BuiltinSkill(
    key: 'regex_help',
    emoji: '🧷',
    name: '写正则',
    summary: '按需求写正则并说明每个部分',
    category: '开发者工具',
    template: '帮我写一个正则表达式：\n'
        '1. 先给出正则本身，用代码块包起来；\n'
        '2. 逐段解释每个部分匹配什么；\n'
        '3. 给出 3 个正例和 2 个反例，并说明为什么；\n'
        '4. 指出这个正则的边界情况（贪婪匹配、换行、Unicode 等）。\n\n'
        '我的需求：{input}',
  ),
  BuiltinSkill(
    key: 'data_to_table',
    emoji: '📊',
    name: '整理成表格',
    summary: '把杂乱数据转成规整表格',
    category: '开发者工具',
    template: '把下面这段杂乱的内容整理成 Markdown 表格：\n'
        '1. 先判断该用哪些列，把同义字段合并到一列；\n'
        '2. 缺失的值填「-」，不要编造；\n'
        '3. 单位、格式统一（日期用 YYYY-MM-DD，金额标明币种）；\n'
        '4. 表格后再用一两句指出数据里值得注意的地方。\n\n'
        '原始内容：\n{input}',
  ),
];

/// 快捷指令服务：提示词模板的增删查，内存缓存供同步读取。
/// 聊天输入「/名称 参数」触发；模板中的 {input} 会被参数替换。
class SkillService {
  SkillService(this._db);

  final AppDatabase _db;

  final List<SkillItem> _cache = [];
  bool _loaded = false;

  List<SkillItem> get skills => List.unmodifiable(_cache);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final rows = await (_db.select(_db.skillItems)
          ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
        .get();
    _cache
      ..clear()
      ..addAll(rows);
  }

  Future<void> addSkill(String name, String template) async {
    await load();
    final row = SkillItem(
      id: uniqueId('skill'),
      name: name,
      template: template,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.into(_db.skillItems).insert(SkillItemsCompanion(
          id: Value(row.id),
          name: Value(row.name),
          template: Value(row.template),
          createdAt: Value(row.createdAt),
        ));
    _cache.insert(0, row);
  }

  Future<void> removeSkill(String id) async {
    await load();
    await (_db.delete(_db.skillItems)..where((s) => s.id.equals(id))).go();
    _cache.removeWhere((s) => s.id == id);
  }

  /// 某个内置技能是否已安装（按指令名判断，避免重复安装）。
  bool isInstalled(BuiltinSkill skill) => findByName(skill.name) != null;

  /// 安装内置技能。已存在同名指令时返回 false，不做任何写入。
  Future<bool> installBuiltin(BuiltinSkill skill) async {
    await load();
    if (isInstalled(skill)) return false;
    await addSkill(skill.name, skill.template);
    return true;
  }

  /// 安装全部内置技能，返回实际新装的数量。
  /// [skip] 为需要跳过的技能（如终端环境未就绪的），跳过的计入 [skipped]。
  Future<({int added, int skipped})> installAllBuiltins({
    bool Function(BuiltinSkill)? skip,
  }) async {
    await load();
    var added = 0;
    var skipped = 0;
    for (final s in builtinSkills) {
      if (skip != null && skip(s)) {
        skipped++;
        continue;
      }
      if (await installBuiltin(s)) added++;
    }
    return (added: added, skipped: skipped);
  }

  /// 设置页展示用：内置技能总数 / 已安装数。
  int get installedBuiltinCount =>
      builtinSkills.where(isInstalled).length;

  SkillItem? findByName(String name) {
    for (final s in _cache) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 把「/名称 参数」展开成完整提示词；无参数时直接返回模板。
  static String expand(SkillItem skill, String args) {
    final trimmed = args.trim();
    if (skill.template.contains('{input}')) {
      return skill.template.replaceAll('{input}', trimmed);
    }
    return trimmed.isEmpty
        ? skill.template
        : '${skill.template}\n\n补充输入：$trimmed';
  }
}
