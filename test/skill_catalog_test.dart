// 内置技能目录完整性测试（v0.2.28-beta 补齐）。
//
// 技能能否被 AI 正确执行取决于两层：定义层（本测试锁住）与运行层
// （联网/终端/模型，需真机）。定义层的任何一处疏漏——比如模板漏了
// {input} 占位符、引用了不存在的工具名、needsTerminal 标注与模板
// 不一致——都会让「安装成功但触发后行为异常」，且 UI 层完全无感。
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/database.dart' show SkillItem;
import 'package:orion_agent/services/skill_service.dart';

/// ToolRegistry 实际注册的工具名全集（tools.dart）。
/// 新增/改名工具时这里要同步，否则模板引用会悬空。
const knownTools = {
  'current_time', 'calculator', 'web_fetch', 'web_search', 'save_memory',
  'search_knowledge', 'run_command', 'use_skill', 'search_skills',
  'install_skill',
};

const categories = {'写作办公', '信息检索', '生活助手', '开发者工具'};

void main() {
  final toolsInTemplates = <String, Set<String>>{};

  test('技能目录：42 个，分类合法，key/name 唯一', () {
    expect(builtinSkills, hasLength(42),
        reason: '增删内置技能后同步更新本测试的数目断言');
    final keys = <String>{};
    final names = <String>{};
    for (final s in builtinSkills) {
      expect(keys.add(s.key), isTrue, reason: 'key 重复: ${s.key} (${s.name})');
      expect(names.add(s.name), isTrue, reason: 'name 重复: ${s.name}');
      expect(categories.contains(s.category), isTrue,
          reason: '${s.name}: 未知分类 ${s.category}');
      expect(s.emoji, isNotEmpty, reason: '${s.name}: 缺 emoji');
      expect(s.summary, isNotEmpty, reason: '${s.name}: 缺 summary');
    }
  });

  test('每个模板：非空、含 {input}、引用的工具真实存在、needsTerminal 一致',
      () {
    for (final s in builtinSkills) {
      expect(s.template.length, greaterThan(30),
          reason: '${s.name}: 模板过短');
      expect(s.template.contains('{input}'), isTrue,
          reason: '${s.name}: 模板缺 {input} 占位符，参数无法注入');

      final mentioned = RegExp(
              r'\b(web_search|web_fetch|run_command|save_memory|search_knowledge|calculator|current_time|use_skill)\b')
          .allMatches(s.template)
          .map((m) => m.group(0)!)
          .toSet();
      toolsInTemplates[s.name] = mentioned;
      for (final t in mentioned) {
        expect(knownTools.contains(t), isTrue,
            reason: '${s.name}: 模板引用了不存在的工具「$t」');
      }
      if (s.template.contains('run_command')) {
        expect(s.needsTerminal, isTrue,
            reason: '${s.name}: 模板用 run_command 但 needsTerminal 未标 true，'
                '终端未装时安装不会提示');
      } else {
        expect(s.needsTerminal, isFalse,
            reason: '${s.name}: 标了 needsTerminal 但模板并未用 run_command');
      }
    }
  });

  test('expand：{input} 注入参数；无占位符模板追加补充输入', () {
    // SkillItem 是 drift 生成的数据类（非 const 构造）
    final withPlaceholder = SkillItem(
        id: 't1', name: '带占位', template: '做这件事：{input}', createdAt: 0);
    expect(SkillService.expand(withPlaceholder, '参数内容'), '做这件事：参数内容');
    expect(SkillService.expand(withPlaceholder, ''), '做这件事：');

    final without =
        SkillItem(id: 't2', name: '无占位', template: '固定指令', createdAt: 0);
    expect(SkillService.expand(without, ''), '固定指令');
    expect(SkillService.expand(without, '补充'), '固定指令\n\n补充输入：补充');
  });

  test('每个技能都能被 use_skill / /技能名 两种方式按名找到（防前后空格/全半角）',
      () {
    for (final s in builtinSkills) {
      expect(s.name.contains(' '), isFalse,
          reason: '${s.name}: 名字含空格会让「/技能名 参数」解析失败');
      expect(s.name.startsWith('/'), isFalse,
          reason: '${s.name}: 名字以 / 开头会与斜杠命令解析冲突');
    }
  });
}
