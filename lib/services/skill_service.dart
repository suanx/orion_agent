import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

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
  BuiltinSkill(
    key: 'install_soushen',
    emoji: '🕵️',
    name: '装搜索增强',
    summary: '安装 soushen-hunter 搜索工具（Bing/Google 零 API 费用）',
    category: '开发者工具',
    needsTerminal: true,
    template: '请在内置 Linux 终端环境（Debian）里安装 soushen-hunter 搜索工具：\n'
        '0. 先确认当前发行版是 Debian：用 run_command 执行 cat /etc/os-release；'
        '如果是 Alpine（musl），直接告诉我：soushen-hunter 不支持 Alpine'
        '（Playwright 无 musl 支持），请到「我的 → 终端环境」切换安装 Debian 后再运行本技能；\n'
        '1. 再检查是否已装：test -x /root/soushen-hunter/soushen && echo INSTALLED；'
        '已装则直接告诉我可用，跳过后面步骤；\n'
        '2. 安装 chromium 与 playwright（体积约 300MB，请耐心；命令涉及安装，会弹确认卡，请同意）：\n'
        '   apt-get update && apt-get install -y --no-install-recommends chromium && pip3 install --break-system-packages playwright\n'
        '3. 下载 soushen-hunter 本体：\n'
        '   curl -L https://codeload.github.com/hexian2001/soushen-hunter/tar.gz/refs/heads/main -o /tmp/ss.tgz\n'
        '   tar -xzf /tmp/ss.tgz -C /root && mv /root/soushen-hunter-main /root/soushen-hunter\n'
        '4. 验证：cd /root/soushen-hunter && ./soushen --help，能输出 JSON 帮助即成功；\n'
        '5. 装完做一次实测：./soushen "天气" --num 3，把结果讲给我听。\n'
        '每一步报错都先读报错再处理，不要原样重试。\n\n'
        '补充要求（可留空）：{input}',
  ),
  BuiltinSkill(
    key: 'soushen_search',
    emoji: '🎯',
    name: '深度搜索',
    summary: '用 soushen-hunter 走 Bing/Google 深度搜索',
    category: '开发者工具',
    needsTerminal: true,
    template: '请用终端里的 soushen-hunter 做一次深度搜索：\n'
        '1. 先确认当前是 Debian 环境（cat /etc/os-release），并确认已安装：'
        'test -x /root/soushen-hunter/soushen；'
        '当前是 Alpine 或未安装时，提示我：soushen 仅支持 Debian，'
        '请切换到 Debian 并运行「装搜索增强」技能，不要擅自改装；\n'
        '2. 用 run_command 执行：cd /root/soushen-hunter && ./soushen \'关键词\' --num 10；'
        '普通结果不够时加 --engine google 再搜一轮；\n'
        '3. 输出是 JSON（results 数组：title/url/snippet/source），解析后按'
        '「标题 + 一句话说明 + 链接」整理给我，按相关性排序；\n'
        '4. 重要结论注明来源链接，查不到的直说。\n\n'
        '搜索关键词与要求：{input}',
  ),
  BuiltinSkill(
    key: 'soushen_deep',
    emoji: '🕸️',
    name: '网页结构分析',
    summary: '用 soushen-hunter 提取页面的链接/表单/按钮/脚本',
    category: '开发者工具',
    needsTerminal: true,
    template: '请用终端里的 soushen-hunter 对目标网页做深度结构分析：\n'
        '1. 先确认当前是 Debian 环境且已安装（cat /etc/os-release + '
        'test -x /root/soushen-hunter/soushen）；'
        'Alpine 或未安装时提示我：soushen 仅支持 Debian，'
        '请切换到 Debian 并运行「装搜索增强」技能；\n'
        '2. 用 run_command 执行：cd /root/soushen-hunter && ./soushen --deep \'目标URL\'；'
        '内容太长时可以加 2>/dev/null 并分段读取；\n'
        '3. 输出是 JSON（page.title / links / forms / buttons / scripts / meta），'
        '按「页面是什么 → 关键链接清单 → 表单与交互点 → 技术栈线索」归纳；\n'
        '4. 最后给出 1~2 条这个页面值得注意的观察（如登录入口、外部依赖）。\n\n'
        '目标 URL 与关注点：{input}',
  ),
  BuiltinSkill(
    key: 'write_unit_test',
    emoji: '🧪',
    name: '写单元测试',
    summary: '为给定代码设计并写出单元测试',
    category: '开发者工具',
    template: '帮我为下面的代码写单元测试：\n'
        '1. 先列出需要覆盖的场景：正常路径、边界值、异常输入，逐条说明为什么测它；\n'
        '2. 用与原代码相同的语言和主流测试框架（如 pytest / JUnit / flutter_test），'
        '给出完整可运行的测试代码；\n'
        '3. 每个测试只测一件事，命名能自解释；\n'
        '4. 指出原代码里难以测试的设计（如硬编码依赖），给一句改进建议。\n\n'
        '代码（注明语言/框架）：\n{input}',
  ),
  BuiltinSkill(
    key: 'code_review',
    emoji: '🔍',
    name: '代码审查',
    summary: '按正确性/安全/可维护性逐项审查',
    category: '开发者工具',
    template: '请对下面的代码做一次代码审查：\n'
        '1. 按严重程度分级输出问题：🔴 必须修（正确性/安全）、🟡 建议改（性能/可读性）、🟢 可选（风格）；\n'
        '2. 每个问题给出「位置 + 问题描述 + 修改后的代码片段」，不要只说问题不给改法；\n'
        '3. 重点检查：空值与边界、并发与资源释放、错误处理、注入与越权；\n'
        '4. 最后用三句话总结这段代码的整体质量与最大风险。\n\n'
        '代码（注明语言与上下文）：\n{input}',
  ),
  BuiltinSkill(
    key: 'refactor_advice',
    emoji: '🛠️',
    name: '重构建议',
    summary: '在不动行为的前提下改善结构',
    category: '开发者工具',
    template: '请为下面的代码给出重构建议：\n'
        '1. 先用一句话概括这段代码现在的职责与问题（过长？耦合？重复？）；\n'
        '2. 给出重构方案：拆成哪些模块/函数、各自职责、依赖方向，附重构后的骨架代码；\n'
        '3. 保持对外行为完全不变，明确列出「哪些调用方需要同步修改」；\n'
        '4. 给出分步实施顺序，每步都可独立验证。\n\n'
        '代码与背景：\n{input}',
  ),
  BuiltinSkill(
    key: 'sql_helper',
    emoji: '🗄️',
    name: '写SQL',
    summary: '按需求写 SQL 并解释执行思路',
    category: '开发者工具',
    template: '帮我写 SQL：\n'
        '1. 先确认我用的数据库（MySQL/PostgreSQL/SQLite），方言差异要标注；\n'
        '2. 给出格式化、可直接执行的 SQL，复杂查询分步骤拆解（CTE 优于嵌套）；\n'
        '3. 逐条解释关键子句在做什么；\n'
        '4. 提示性能：哪些条件会走索引、哪些会全表扫，给出建议的索引；\n'
        '5. 表结构不清楚的地方先列出来问我，不要瞎猜字段名。\n\n'
        '需求与表结构：\n{input}',
  ),
  BuiltinSkill(
    key: 'git_helper',
    emoji: '🌿',
    name: 'Git助手',
    summary: '在终端里完成 Git 操作与提交信息',
    category: '开发者工具',
    needsTerminal: true,
    template: '请作为 Git 助手在终端环境里帮我处理版本管理：\n'
        '1. 先用 run_command 执行 git status 与 git log --oneline -5 看清当前状态；\n'
        '2. 按我的要求操作（暂存/提交/分支/回退），每条命令执行前说明它做什么；'
        '涉及 push --force、reset --hard 这类破坏性操作必须先向我确认；\n'
        '3. 提交信息用「类型: 摘要」格式（feat/fix/chore/docs），一行说清变更；\n'
        '4. 遇到冲突时逐个文件分析冲突块，给出保留建议让我选。\n\n'
        '我要做的 Git 操作：\n{input}',
  ),
  BuiltinSkill(
    key: 'dockerfile_help',
    emoji: '🐳',
    name: '写Dockerfile',
    summary: '生成多阶段构建的生产级镜像配置',
    category: '开发者工具',
    template: '帮我为下面的项目写 Dockerfile：\n'
        '1. 优先多阶段构建：编译阶段与运行阶段分离，运行镜像尽量小（alpine/slim）；\n'
        '2. 合并 RUN 层、清理包管理缓存，说明每一层在做什么；\n'
        '3. 用非 root 用户运行，声明 EXPOSE 与健康检查；\n'
        '4. 给出配套的 .dockerignore 建议；\n'
        '5. 如果是常见框架（Spring Boot / Node / Flutter web / Go），直接按最佳实践给完整文件。\n\n'
        '项目情况（语言/构建工具/入口）：\n{input}',
  ),
  BuiltinSkill(
    key: 'perf_tuning',
    emoji: '⚡',
    name: '排查性能瓶颈',
    summary: '在终端里实测并定位慢在哪里',
    category: '开发者工具',
    needsTerminal: true,
    template: '请在终端环境里帮我排查性能问题：\n'
        '1. 先问清或从输入判断：慢的是启动、接口还是批处理；\n'
        '2. 用 run_command 实测取证：time 计时、top/ps 看占用、对疑似瓶颈单独计时，'
        '把实测数据贴出来，不要凭感觉下结论；\n'
        '3. 按收益排序给出优化建议：每条写清「预计收益 + 改动量 + 风险」；\n'
        '4. 改动执行后再跑一次同样的计时命令，给出前后对比。\n\n'
        '性能问题描述：\n{input}',
  ),
  BuiltinSkill(
    key: 'api_debug',
    emoji: '🔌',
    name: '接口调试',
    summary: '用 curl 实测接口并解读响应',
    category: '开发者工具',
    needsTerminal: true,
    template: '请用终端环境调试这个接口：\n'
        '1. 用 run_command 执行 curl 实测（-sS -w 带 HTTP 状态码与耗时；'
        'curl 属于网络命令，会弹确认卡，请同意）：\n'
        '   curl -sS -w "\\nHTTP %{http_code} 耗时%{time_total}s\\n" -X POST 地址 -H 头 -d 数据\n'
        '2. 解读响应：状态码含义、body 结构、关键字段；异常时区分 4xx（我的问题）与 5xx（对方问题）；\n'
        '3. 鉴权失败、参数错误的场景各试一次，总结出最小可用请求；\n'
        '4. 注意：不要把 Authorization 头的完整值回显给我。\n\n'
        '接口信息（地址/方法/头/示例数据）：\n{input}',
  ),
  BuiltinSkill(
    key: 'shell_helper',
    emoji: '🐚',
    name: '写Shell脚本',
    summary: '写健壮、可维护的 Bash 脚本',
    category: '开发者工具',
    template: '帮我写一个 Bash 脚本：\n'
        '1. 开头用 set -euo pipefail，关键变量集中定义，支持必要参数与 --help；\n'
        '2. 每个关键步骤有日志输出（前缀时间戳），失败时给出可读错误并退出非零；\n'
        '3. 临时文件用 mktemp 并在退出时清理；\n'
        '4. 逐段解释脚本逻辑，标出可按需修改的常量；\n'
        '5. 说明如何在终端环境里运行与排错。\n\n'
        '脚本要完成的任务：\n{input}',
  ),
  BuiltinSkill(
    key: 'meeting_notes',
    emoji: '📋',
    name: '会议纪要',
    summary: '把口述的会议内容整理成纪要',
    category: '写作办公',
    template: '把我口述的会议内容整理成正式纪要：\n'
        '1. 结构：会议主题 / 时间与参与人（缺就标「待补充」）/ 结论 / 待办；\n'
        '2. 结论按议题分组，每个议题一句结论；\n'
        '3. 待办写成「事项 · 负责人 · 截止时间」表格，没有的标待定；\n'
        '4. 不确定的表述保留原话并标注，不要替我下结论。\n\n'
        '会议内容（口述即可，不用整理）：\n{input}',
  ),
  BuiltinSkill(
    key: 'official_doc',
    emoji: '📜',
    name: '通知公文',
    summary: '按公文格式起草通知/申请',
    category: '写作办公',
    template: '帮我起草一份正式通知/申请：\n'
        '1. 结构：标题 / 称谓 / 正文（背景一句 + 事项分条）/ 结尾用语 / 落款与日期；\n'
        '2. 语气正式克制，不用网络用语，不用感叹号；\n'
        '3. 涉及时间、地点、金额的信息必须准确引用我给的原文；\n'
        '4. 字数控制在 300 字内，除非我另有要求。\n\n'
        '事项与要点：\n{input}',
  ),
  BuiltinSkill(
    key: 'product_prd',
    emoji: '📐',
    name: '产品需求文档',
    summary: '把模糊想法整理成结构化 PRD',
    category: '写作办公',
    template: '帮我把下面这个想法整理成一份轻量 PRD：\n'
        '1. 结构：背景与目标 / 目标用户与场景 / 功能需求（按优先级 P0/P1/P2）/'
        '非功能需求 / 边界与不做的事 / 成功指标；\n'
        '2. 每个功能需求写「用户故事 + 验收标准」；\n'
        '3. 把我没想到但必须回答的问题列在「待确认」一节，不要替我拍板；\n'
        '4. 全文不超过 800 字。\n\n'
        '想法与背景：\n{input}',
  ),
  BuiltinSkill(
    key: 'title_ideas',
    emoji: '🎯',
    name: '标题起名',
    summary: '一批不同风格的标题候选',
    category: '写作办公',
    template: '帮下面的内容起标题：\n'
        '1. 给 10 个候选，分三种风格：稳重准确（4 个）、吸引点击但不标题党（3 个）、'
        '简短有力（3 个）；\n'
        '2. 每个标题后用括号标注适用场景（公众号/简历项目/应用商店等）；\n'
        '3. 关键信息（数字、主体、结果）必须在标题里出现；\n'
        '4. 最后推荐 1 个并说明理由。\n\n'
        '内容与用途：\n{input}',
  ),
  BuiltinSkill(
    key: 'company_research',
    emoji: '🏛️',
    name: '公司背调',
    summary: '面试/合作前调查公司背景',
    category: '信息检索',
    template: '请联网调查下面这家公司的背景：\n'
        '1. 用 web_search 检索：公司主体、成立时间、规模、主营业务、近期动态；\n'
        '2. 用 web_fetch 读取官网与 1~2 篇可信报道（优先一手来源）；\n'
        '3. 输出：基本情况 / 业务与产品 / 口碑与风险（劳动纠纷、经营异常等，注明来源）/\n'
        '   给我的建议（面试或合作时值得确认的问题）；\n'
        '4. 查不到的信息明确标注「未查到」，不要拼凑猜测。\n\n'
        '公司名称与调查目的：\n{input}',
  ),
  BuiltinSkill(
    key: 'paper_search',
    emoji: '🎓',
    name: '学术检索',
    summary: '找论文并给出结构化综述',
    category: '信息检索',
    template: '请帮我检索学术资料：\n'
        '1. 用 web_search 检索（可加 site:arxiv.org / site:scholar.google.com 等限定）；\n'
        '2. 找 3~5 篇最相关论文/技术报告，每篇给出：标题、作者与年份、链接、'
        '一句话核心贡献；\n'
        '3. 按时间线简述这个方向的发展脉络与当前主流做法；\n'
        '4. 区分「同行评审论文」与「预印本/博客」，不要混为一谈；\n'
        '5. 找不到正式论文时明确说明，用技术博客兜底并标注。\n\n'
        '研究方向或问题：\n{input}',
  ),
  BuiltinSkill(
    key: 'competitor_analysis',
    emoji: '🏁',
    name: '竞品分析',
    summary: '结构化对比同类产品的打法',
    category: '信息检索',
    template: '请做一份轻量竞品分析：\n'
        '1. 用 web_search/web_fetch 检索指定产品及其主要竞品（3 个以内）；\n'
        '2. 对比维度：目标用户 / 核心功能 / 定价模式 / 差异化卖点 / 明显短板；\n'
        '3. 用 Markdown 表格呈现，信息缺失的格子写「未公开」，不要编造；\n'
        '4. 给出 2~3 条可借鉴的策略与 1 条差异化建议，注明依据；\n'
        '5. 所有事实性内容必须带来源链接。\n\n'
        '我的产品/方向与已知竞品：\n{input}',
  ),
  BuiltinSkill(
    key: 'recipe_idea',
    emoji: '🍳',
    name: '菜谱推荐',
    summary: '按现有食材出菜单和步骤',
    category: '生活助手',
    template: '根据我现有的食材推荐做法：\n'
        '1. 给 2~3 个菜的组合（一荤一素一汤优先），说明选择理由；\n'
        '2. 每个菜给出步骤（控制在 5 步内）、火候关键点和大致耗时；\n'
        '3. 缺的调料/食材单独列采购清单，标注可替代项；\n'
        '4. 有忌口或过敏要求的严格规避，我不说就先问一句。\n\n'
        '现有食材与忌口：\n{input}',
  ),
  BuiltinSkill(
    key: 'fitness_plan',
    emoji: '💪',
    name: '健身计划',
    summary: '按基础和目标排训练计划',
    category: '生活助手',
    template: '帮我制定一份健身计划：\n'
        '1. 先确认：当前基础（是否新手）、每周可练次数、场地（家里/健身房）、'
        '有无伤病史——信息不全先问我；\n'
        '2. 排 4 周计划：每次训练的动作组数次数、组间休息、每周安排；\n'
        '3. 新手优先复合动作与循序渐进，不安排高冲击动作；\n'
        '4. 每个动作给一句要点（避免常见错误），标注需要热身的部位；\n'
        '5. 给出「什么情况下应停练」的提醒。\n\n'
        '我的情况与目标：\n{input}',
  ),
  BuiltinSkill(
    key: 'english_plan',
    emoji: '🗣️',
    name: '学英语计划',
    summary: '按水平和目标定制学习方案',
    category: '生活助手',
    template: '帮我定制英语学习计划：\n'
        '1. 先确认：当前水平（词汇量/能否开口）、目标（考试/工作/口语）、'
        '每天可投入时间——不全就先问；\n'
        '2. 给 4 周计划：每天 30~60 分钟的具体安排（输入/输出/复盘各占比）；\n'
        '3. 推荐具体材料与工具（免费优先），说明为什么适合我的水平；\n'
        '4. 每周一个可检验的小目标（如听懂一段播客/写一篇短文）；\n'
        '5. 指出我这类目标最常见的三个坑。\n\n'
        '我的水平与目标：\n{input}',
  ),
  BuiltinSkill(
    key: 'rent_check',
    emoji: '🏠',
    name: '租房避坑',
    summary: '看房要点清单与合同风险项',
    category: '生活助手',
    template: '帮我把这次租房看房安排稳妥：\n'
        '1. 给一份看房现场检查清单：水电燃气、网络、隔音、家电损耗、'
        '周边配套（超市/地铁/医院），逐项写「怎么验」；\n'
        '2. 给合同风险清单：押金退还条件、转租条款、维修责任、涨租机制、'
        '提前退租违约金，逐条写「什么表述有坑」；\n'
        '3. 需要了解当地行情时先联网检索（web_search），注明来源；\n'
        '4. 最后给一份「签约前必须确认的 5 件事」。\n\n'
        '城市/区域、预算、通勤要求：\n{input}',
  ),
  BuiltinSkill(
    key: 'gift_idea',
    emoji: '🎁',
    name: '送礼参谋',
    summary: '按对象预算给有理由的礼物清单',
    category: '生活助手',
    template: '帮我想礼物方案：\n'
        '1. 给 5 个候选，按「稳妥 / 有心思 / 惊喜」分三档；\n'
        '2. 每个写清：推荐理由（与对方的关系/性格/近期状态挂钩）、'
        '大致价位、需要提前多久准备；\n'
        '3. 涉及具体商品价格时联网核实（web_search），注明来源；\n'
        '4. 单独列出「不要送」的雷区（结合对象身份与场合）；\n'
        '5. 信息不足时先问我对方是谁、什么场合、预算。\n\n'
        '送对象、场合与预算：\n{input}',
  ),
];

/// 快捷指令服务：提示词模板的增删查，内存缓存供同步读取。
/// 聊天输入「/名称 参数」触发；模板中的 {input} 会被参数替换。
class SkillService {
  SkillService(this._db);

  final AppDatabase _db;

  final List<SkillItem> _cache = [];
  bool _loaded = false;
  bool _loading = false;

  List<SkillItem> get skills => List.unmodifiable(_cache);

  /// 只在查询【成功后】才置 _loaded。
  /// 原实现 await 之前就置位，若查询抛异常（首次打开、DB 损坏、schema 迁移中），
  /// _loaded 已是 true 而 _cache 仍为空 —— 此后整个 App 生命周期内 load() 都是
  /// no-op：isInstalled() 恒false（用户可重复安装同一技能、不断插重复行），
  /// findByName() 恒null（`/技能名` 触发全部失效）。
  Future<void> load() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final rows = await (_db.select(_db.skillItems)
            ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
          .get();
      _cache
        ..clear()
        ..addAll(rows);
      _loaded = true;
    } catch (e) {
      debugPrint('技能列表加载失败：$e');
      rethrow;
    } finally {
      // 失败后允许重试
      _loading = false;
    }
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
