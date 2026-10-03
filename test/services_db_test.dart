import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/database.dart';
import 'package:orion_agent/services/role_service.dart';
import 'package:orion_agent/services/skill_service.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  group('SkillService', () {
    test('增删查与按名查找', () async {
      final skills = SkillService(db);
      await skills.addSkill('周报', '把以下内容整理成周报：{input}');
      await skills.addSkill('翻译', '把 {input} 翻译成英文');

      expect(skills.skills, hasLength(2));
      expect(skills.findByName('周报')?.template, '把以下内容整理成周报：{input}');
      expect(skills.findByName('不存在'), isNull);

      await skills.removeSkill(skills.skills.first.id);
      expect(skills.skills, hasLength(1));

      final fresh = SkillService(db);
      await fresh.load();
      expect(fresh.skills, hasLength(1));
    });

    test('expand：{input} 占位与追加两种模式', () {
      final withPlaceholder = SkillItem(
        id: 'a',
        name: '周报',
        template: '整理成周报：{input}',
        createdAt: 0,
      );
      expect(SkillService.expand(withPlaceholder, '写完了 A 和 B'),
          '整理成周报：写完了 A 和 B');
      expect(SkillService.expand(withPlaceholder, ''), '整理成周报：');

      final plain = SkillItem(
        id: 'b',
        name: '天气',
        template: '查一下今天的天气',
        createdAt: 0,
      );
      expect(SkillService.expand(plain, ''), '查一下今天的天气');
      expect(SkillService.expand(plain, '北京'), '查一下今天的天气\n\n补充输入：北京');
    });

    test('同毫秒连续添加不冲突', () async {
      final skills = SkillService(db);
      await skills.addSkill('a', 'A');
      await skills.addSkill('b', 'B');
      await skills.addSkill('c', 'C');
      expect(skills.skills, hasLength(3));
      final ids = skills.skills.map((s) => s.id).toSet();
      expect(ids.length, 3);
    });
  });

  group('RoleService', () {
    test('增改删与跨实例读回', () async {
      final roles = RoleService(db);
      await roles.addRole('技术翻译', '只输出译文，不解释');
      expect(roles.roles, hasLength(1));

      final id = roles.roles.single.id;
      await roles.updateRole(id, '技术翻译', '只输出译文，保留代码原样');
      expect(roles.promptOf(id), '只输出译文，保留代码原样');

      final fresh = RoleService(db);
      await fresh.load();
      expect(fresh.roles.single.prompt, '只输出译文，保留代码原样');

      await fresh.removeRole(id);
      expect(fresh.roles, isEmpty);
      expect(fresh.promptOf(id), isNull);
    });
  });
}
