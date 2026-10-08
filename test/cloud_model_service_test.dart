import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/models/llm_config.dart';
import 'package:orion_agent/services/cloud_model_service.dart';
import 'package:orion_agent/services/cloud_service.dart';

/// 云端模型接入的纯逻辑单测。
///
/// 锁住三件事：
/// 1. 后端下发的供应商能正确包装成本地 LlmConfig（fullUrl + 模型列表）
/// 2. 周额度模型的前端解析与文案（含耗尽/重置倒计时）
/// 3. 云端配置的识别与过滤规则（不落盘、不入用户配置列表）
void main() {
  group('CloudAiQuota 解析与文案', () {
    test('正常解析后端字段', () {
      final q = CloudAiQuota.fromJson(const {
        'tier': 'pro',
        'tierLabel': '专业版',
        'used': 120,
        'limit': 1000,
        'remaining': 880,
        'resetInMs': 3 * 86400000,
      });
      expect(q.tier, 'pro');
      expect(q.tierLabel, '专业版');
      expect(q.used, 120);
      expect(q.limit, 1000);
      expect(q.remaining, 880);
      expect(q.isSupported, isTrue);
      expect(q.isExhausted, isFalse);
      expect(q.usedFraction, closeTo(0.12, 1e-9));
    });

    test('空响应（旧版后端未下发该字段）→ isSupported=false 且不显示', () {
      final q = CloudAiQuota.fromJson(const {});
      expect(q.isSupported, isFalse);
      expect(q.isExhausted, isFalse);
      // limit=0 时 usedFraction 不能除零
      expect(q.usedFraction, 0.0);
      expect(q.resetText, '');
    });

    test('remaining 缺失时自己算 limit-used', () {
      final q = CloudAiQuota.fromJson(const {'limit': 100, 'used': 30});
      expect(q.remaining, 70);
    });

    test('remaining 为负（后端脏数据）时钳到 0', () {
      final q = CloudAiQuota.fromJson(const {'limit': 100, 'used': 150});
      expect(q.remaining, 0);
      expect(q.isExhausted, isTrue);
    });

    test('耗尽判定', () {
      final q = CloudAiQuota.fromJson(const {'limit': 100, 'used': 100});
      expect(q.remaining, 0);
      expect(q.isExhausted, isTrue);
      expect(q.usedFraction, 1.0);
    });

    test('重置倒计时文案：天/小时/即将', () {
      String text(int ms) =>
          CloudAiQuota.fromJson({'limit': 100, 'resetInMs': ms}).resetText;
      expect(text(3 * 86400000), '3 天后重置');
      expect(text(2 * 3600000), '2 小时后重置');
      expect(text(30 * 60000), '1 小时内重置');
      expect(text(0), '即将重置');
    });

    test('免费/专业/永久三档的中文名透传', () {
      for (final e in {'free': '免费版', 'pro': '专业版', 'lifetime': '永久版'}.entries) {
        final q = CloudAiQuota.fromJson({'tier': e.key, 'tierLabel': e.value});
        expect(q.tierLabel, e.value);
      }
    });
  });

  group('CloudModelProvider 解析', () {
    test('解析供应商与模型，聊天/向量按 kind 分开', () {
      final p = CloudModelProvider.fromJson(const {
        'id': 'p_1',
        'name': '官方中转',
        'chatUrl': 'https://orion.example.com/api/ai/chat',
        'models': [
          {'name': 'm-chat', 'label': '快模型', 'contextWindow': 128000},
          {'name': 'm-emb', 'kind': 'embedding'},
        ],
      });
      expect(p.id, 'p_1');
      expect(p.name, '官方中转');
      expect(p.models.length, 2);
      // 对话界面只列聊天模型
      expect(p.chatModels.length, 1);
      expect(p.chatModels.first.name, 'm-chat');
      expect(p.chatModels.first.contextWindow, 128000);
    });

    test('缺 label 时展示名回落到 name', () {
      final m = CloudModelSpec.fromJson(const {'name': 'gpt-x'});
      expect(m.displayLabel, 'gpt-x');
      expect(m.kind, 'chat');
      expect(m.contextWindow, 0);
    });

    test('kind 缺失默认 chat（后端老数据无 kind 时仍能用）', () {
      final p = CloudModelProvider.fromJson(const {
        'id': 'p',
        'name': 'n',
        'chatUrl': 'u',
        'models': [
          {'name': 'a'},
        ],
      });
      expect(p.chatModels.length, 1);
    });
  });

  group('云端配置包装为 LlmConfig', () {
    final provider = CloudModelProvider.fromJson(const {
      'id': 'p_abc',
      'name': '官方中转',
      'chatUrl': 'https://orion.example.com/api/ai/chat',
      'models': [
        {'name': 'm1'},
        {'name': 'm2', 'contextWindow': 200000},
        {'name': 'm-emb', 'kind': 'embedding'},
      ],
    });

    test('fullUrl=true 且 baseUrl 就是中继完整地址', () {
      final c = CloudModelService.toConfig(provider);
      // 后端路径不是 OpenAI 标准路径，绝不能再拼 /chat/completions
      expect(c.fullUrl, isTrue);
      expect(c.baseUrl, 'https://orion.example.com/api/ai/chat');
      expect(c.baseUrl.endsWith('/chat/completions'), isFalse);
    });

    test('模型列表只含聊天模型，默认选中第一个', () {
      final c = CloudModelService.toConfig(provider);
      expect(c.models.length, 2);
      expect(c.models.every((m) => m.kind == ModelKind.chat), isTrue);
      expect(c.defaultChatModel, 'm1');
      expect(c.chatModel?.name, 'm1');
    });

    test('id 带 cloud: 前缀，便于识别与清理', () {
      final c = CloudModelService.toConfig(provider);
      expect(c.id, 'cloud:p_abc');
      expect(CloudModelService.isCloud(c), isTrue);
    });

    test('apiKey 是占位串（真正鉴权走登录令牌）', () {
      final c = CloudModelService.toConfig(provider);
      expect(c.apiKey, CloudModelService.placeholderApiKey);
      // 非空即可——空 Key 会被 LlmClient 直接拒绝发请求
      expect(c.apiKey.isNotEmpty, isTrue);
    });

    test('展示名标注「云端」，与用户自建配置区分', () {
      final c = CloudModelService.toConfig(provider);
      expect(c.name.contains('云端'), isTrue);
    });

    test('没有聊天模型的供应商不产出配置', () {
      final onlyEmb = CloudModelProvider.fromJson(const {
        'id': 'p',
        'name': 'n',
        'chatUrl': 'u',
        'models': [
          {'name': 'e', 'kind': 'embedding'},
        ],
      });
      expect(CloudModelService.toConfigs([onlyEmb]), isEmpty);
    });

    test('chatUrl 为空（后端数据不全）时跳过，避免发出无效请求', () {
      final noUrl = CloudModelProvider.fromJson(const {
        'id': 'p',
        'name': 'n',
        'chatUrl': '',
        'models': [
          {'name': 'm'},
        ],
      });
      expect(CloudModelService.toConfigs([noUrl]), isEmpty);
    });

    test('多供应商 → 多条配置，id 互不冲突', () {
      final list = CloudModelService.toConfigs([
        provider,
        CloudModelProvider.fromJson(const {
          'id': 'p_def',
          'name': '备用',
          'chatUrl': 'https://x/api/ai/chat',
          'models': [
            {'name': 'z'},
          ],
        }),
      ]);
      expect(list.length, 2);
      expect(list.map((c) => c.id).toSet().length, 2);
      expect(list.every(CloudModelService.isCloud), isTrue);
    });

    test('非云端配置不会被误判', () {
      final local = CloudModelService.toConfig(provider).copyWith(id: 'local-1');
      expect(CloudModelService.isCloud(local), isFalse);
    });
  });

  group('CloudModelsState', () {
    test('空状态：未登录时不显示入口', () {
      const s = CloudModelsState();
      expect(s.hasModels, isFalse);
      expect(s.available, isFalse);
    });

    test('copyWith 可清除错误', () {
      const s = CloudModelsState(error: 'boom');
      expect(s.copyWith(clearError: true).error, isNull);
    });
  });
}
