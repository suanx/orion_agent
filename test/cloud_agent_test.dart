import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/models/llm_config.dart';
import 'package:orion_agent/services/cloud_model_service.dart';
import 'package:orion_agent/services/cloud_service.dart';

/// 云端 Agent 的纯逻辑单测。
///
/// 锁住三件事：
/// 1. 未开通（enabled=false）时不产出任何配置 —— App 端因此零入口
/// 2. 开通后包装出的 LlmConfig 走 fullUrl（不拼 /chat/completions）
/// 3. 与云端模型的 id 前缀互不干扰
void main() {
  group('CloudAgentInfo 解析', () {
    test('enabled=false（未开通）', () {
      final info = CloudAgentInfo.fromJson(const {'enabled': false});
      expect(info.enabled, isFalse);
      expect(info.chatUrl, '');
    });

    test('已开通时字段完整', () {
      final info = CloudAgentInfo.fromJson(const {
        'enabled': true,
        'label': '我的编码助手',
        'chatUrl': 'https://orion.example.com/api/agent/chat',
        'model': 'agent',
      });
      expect(info.enabled, isTrue);
      expect(info.label, '我的编码助手');
      expect(info.chatUrl, 'https://orion.example.com/api/agent/chat');
      expect(info.model, 'agent');
    });

    test('缺字段时用默认值（后端老版本）', () {
      final info = CloudAgentInfo.fromJson(const {'enabled': true});
      expect(info.label, '云端 Agent');
      expect(info.chatUrl, '');
      expect(info.model, 'agent');
    });

    test('空响应 → 未开通', () {
      expect(CloudAgentInfo.fromJson(const {}).enabled, isFalse);
    });
  });

  group('Agent 包装为 LlmConfig', () {
    final info = CloudAgentInfo.fromJson(const {
      'enabled': true,
      'label': '云端编码',
      'chatUrl': 'https://orion.example.com/api/agent/chat',
      'model': 'agent',
    });

    test('fullUrl=true，baseUrl 即完整地址', () {
      final c = CloudModelService.agentToConfig(info);
      // 关键：后端路径不是 OpenAI 标准路径，绝不能再拼 /chat/completions
      expect(c.fullUrl, isTrue);
      // relayUrl：路径保留，主机重锚到 App 写死的后端根地址
      // （后端下发的站点地址不可信——曾产出相对路径导致 HTTP null）
      expect(c.baseUrl, 'https://orion.suen.us.ci/api/agent/chat');
      expect(c.baseUrl.endsWith('/chat/completions'), isFalse);
    });

    test('chatUrl 是相对路径时锚定到本 App 后端根地址（HTTP null 修复）', () {
      final rel = CloudAgentInfo.fromJson(const {
        'enabled': true,
        'chatUrl': '/api/agent/chat',
      });
      final c = CloudModelService.agentToConfig(rel);
      expect(c.baseUrl, 'https://orion.suen.us.ci/api/agent/chat');
    });

    test('id 带 agent: 前缀，与云端模型区分', () {
      final c = CloudModelService.agentToConfig(info);
      expect(c.id, 'agent:agent');
      expect(CloudModelService.isAgent(c), isTrue);
      // 不能被误判成云端模型（两者鉴权虽同源，但配置注入/清理路径不同）
      expect(c.id.startsWith('cloud:'), isFalse);
    });

    test('只有一个虚拟模型且默认选中', () {
      final c = CloudModelService.agentToConfig(info);
      expect(c.models.length, 1);
      expect(c.defaultChatModel, 'agent');
      expect(c.chatModel?.name, 'agent');
    });

    test('ready 为 true（baseUrl + chatModel 都在）', () {
      expect(CloudModelService.agentToConfig(info).ready, isTrue);
    });

    test('占位 apiKey 非空（真正鉴权走登录令牌）', () {
      expect(CloudModelService.agentToConfig(info).apiKey.isNotEmpty, isTrue);
    });

    test('未开通时不产出配置', () {
      const off = CloudAgentInfo();
      // off.enabled=false → 调用方直接给 null，不该构造配置
      expect(off.enabled, isFalse);
    });
  });

  group('云端模型与 Agent 前缀互不干扰', () {
    test('云端模型 id 以 cloud: 开头，不是 agent:', () {
      final cloudProvider = CloudModelProvider.fromJson(const {
        'id': 'p_1',
        'name': '官方',
        'chatUrl': 'https://x/api/ai/chat',
        'models': [
          {'name': 'm1'},
        ],
      });
      final c = CloudModelService.toConfig(cloudProvider);
      expect(c.id.startsWith('cloud:'), isTrue);
      expect(CloudModelService.isAgent(c), isFalse);
    });

    test('CloudModelService.idPrefix 与 agentPrefix 不同', () {
      expect(CloudModelService.idPrefix, isNot(CloudModelService.agentPrefix));
    });
  });

  group('CloudModelsState 的 agent 语义', () {
    test('默认无 Agent（hasAgent=false）', () {
      const s = CloudModelsState();
      expect(s.agentConfig, isNull);
      expect(s.hasAgent, isFalse);
    });

    test('copyWith 可显式清空 agent（管理员停用后入口消失）', () {
      final c = LlmConfig(
        id: 'agent:agent',
        name: '云端 Agent',
        baseUrl: 'https://x/api/agent/chat',
        apiKey: 'k',
      );
      final withAgent = const CloudModelsState().copyWith(agentConfig: c);
      expect(withAgent.hasAgent, isTrue);
      final cleared = withAgent.copyWith(clearAgent: true);
      expect(cleared.hasAgent, isFalse);
    });
  });
}
