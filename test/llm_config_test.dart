import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/models/llm_config.dart';
import 'package:orion_agent/services/llm_client.dart';

/// 提供商配置的结构变更回归。
///
/// 背景：原先「一条配置 = 一个模型」，现在改成「一个提供商 = 一组模型」
/// （提供商 → 模型 两级）。老用户的数据必须能无损迁移，否则升级后
/// 会出现「模型名不见了、知识库失效」。
void main() {
  group('旧数据迁移', () {
    test('一条聊天配置 → 一个聊天模型，参数全部保留', () {
      final c = LlmConfig.fromJson({
        'id': 'cfg_1',
        'name': 'GLM',
        'baseUrl': 'https://x/v1',
        'apiKey': 'k',
        'model': 'glm-4-flash',
        'kind': 'chat',
        'contextWindow': 128000,
        'maxOutputTokens': 4096,
        'temperature': 0.3,
      });

      expect(c.models, hasLength(1), reason: '实际=${c.models.length}');
      final m = c.models.single;
      expect(m.name, 'glm-4-flash');
      expect(m.kind, ModelKind.chat);
      expect(m.contextWindow, 128000);
      expect(m.maxOutputTokens, 4096);
      expect(m.temperature, 0.3);
      // 派生属性必须仍然可用，否则调用方全部要改
      expect(c.model, 'glm-4-flash');
      expect(c.ready, isTrue);
      // 老数据没 enabled 字段，默认启用，否则升级后一条都不能用
      expect(c.enabled, isTrue);
    });

    test('聊天配置附带 embeddingModel → 迁移出两个模型', () {
      final c = LlmConfig.fromJson({
        'id': 'c2',
        'baseUrl': 'https://x/v1',
        'apiKey': 'k',
        'model': 'gpt-4o-mini',
        'embeddingModel': 'text-embedding-3-small',
      });
      expect(c.models, hasLength(2), reason: '实际=${c.models.length}');
      expect(c.chatModels, hasLength(1));
      expect(c.embeddingModels, hasLength(1));
      // 知识库检索靠这个，迁丢了就会「AI 不认识导入的资料」
      expect(c.embeddingModelName, 'text-embedding-3-small');
    });

    test('纯向量配置迁移后不能用于对话', () {
      final c = LlmConfig.fromJson({
        'id': 'c3',
        'baseUrl': 'https://x/v1',
        'apiKey': 'k',
        'model': 'bge-m3',
        'kind': 'embedding',
      });
      expect(c.embeddingModels, hasLength(1));
      expect(c.chatModel, isNull);
      expect(c.ready, isFalse);
    });

    test('已有 models 字段时不再走迁移（避免重复添加）', () {
      final c = LlmConfig.fromJson({
        'id': 'c4',
        'model': 'legacy-name',
        'models': [
          {'name': 'new-name', 'kind': 'chat'},
        ],
      });
      expect(c.models, hasLength(1));
      expect(c.models.single.name, 'new-name',
          reason: '不该把 legacy 的 model 又塞进来');
    });
  });

  group('序列化往返', () {
    test('全部新字段都能存取', () {
      const src = LlmConfig(
        id: 'c',
        name: 'OpenCode',
        baseUrl: 'https://api.x/v1',
        apiKey: 'k1',
        extraKeys: ['k2', 'k3'],
        userAgent: 'MyUA/1.0',
        enabled: false,
        fullUrl: true,
        promptCacheKey: true,
        multiKey: true,
        proxy: 'http://127.0.0.1:7890',
        models: [
          ProviderModel(
              name: 'a-chat', kind: ModelKind.chat, contextWindow: 64000),
          ProviderModel(name: 'b-embed', kind: ModelKind.embedding),
        ],
        defaultChatModel: 'a-chat',
      );
      final back = LlmConfig.fromJson(src.toJson());

      expect(back.name, src.name);
      expect(back.extraKeys, src.extraKeys);
      expect(back.userAgent, src.userAgent);
      expect(back.enabled, isFalse);
      expect(back.fullUrl, isTrue);
      expect(back.promptCacheKey, isTrue);
      expect(back.multiKey, isTrue);
      expect(back.proxy, src.proxy);
      expect(back.models, hasLength(2));
      expect(back.models.first.contextWindow, 64000);
      expect(back.defaultChatModel, 'a-chat');
    });
  });

  group('派生属性', () {
    const base = LlmConfig(
      id: 'c',
      name: 'P',
      baseUrl: 'https://api.x/v1',
      apiKey: 'k1',
      extraKeys: ['k2', 'k3'],
      multiKey: true,
      models: [
        ProviderModel(name: 'chat1', kind: ModelKind.chat),
        ProviderModel(name: 'chat2', kind: ModelKind.chat),
        ProviderModel(name: 'emb1', kind: ModelKind.embedding),
      ],
      defaultChatModel: 'chat2',
    );

    test('effectiveKeys 受多 Key 开关控制', () {
      expect(base.effectiveKeys, ['k1', 'k2', 'k3']);
      expect(base.copyWith(multiKey: false).effectiveKeys, ['k1'],
          reason: '关闭多 Key 时不该带上备用 Key');
      expect(base.copyWith(apiKey: '   ').copyWith(multiKey: false)
          .effectiveKeys, isEmpty,
          reason: '主 Key 只有空白时视为未配置');
    });

    test('chatModel 优先用 defaultChatModel，失效则回退', () {
      expect(base.chatModel?.name, 'chat2');
      expect(base.copyWith(defaultChatModel: '已删除').chatModel?.name, 'chat1',
          reason: '指定的模型被删掉时必须回退，不能变成不能对话');
      expect(base.embeddingModel?.name, 'emb1');
    });

    test('displayName 逐级降级', () {
      expect(base.displayName, 'P');
      expect(base.copyWith(name: '').displayName, 'api.x');
      expect(base.copyWith(name: '', baseUrl: '').displayName, '未命名提供商');
    });

    test('modelCountLabel 与 ready', () {
      expect(base.modelCountLabel, '3 个模型');
      expect(base.ready, isTrue);
      expect(base.copyWith(baseUrl: '').ready, isFalse);
      expect(
        base.copyWith(models: const [
          ProviderModel(name: 'only-emb', kind: ModelKind.embedding),
        ]).ready,
        isFalse,
        reason: '只有向量模型时不能对话',
      );
    });
  });

  group('坏输入容错', () {
    test('非列表的 models / extraKeys 不崩', () {
      final c = LlmConfig.fromJson({
        'id': 'c',
        'extraKeys': 'not a list',
        'models': 'not a list',
      });
      expect(c.extraKeys, isEmpty);
      expect(c.models, isEmpty);
    });

    test('extraKeys 过滤非字符串与空白项', () {
      final c = LlmConfig.fromJson({
        'extraKeys': [1, 'good', null, '  ', 'ok2'],
      });
      expect(c.extraKeys, ['good', 'ok2']);
    });
  });

  group('请求地址推导', () {
    LlmConfig c(String url, {bool full = false}) => LlmConfig(
        id: 'i', name: 'n', baseUrl: url, apiKey: 'k', fullUrl: full);

    test('普通模式自动拼路径，容忍尾斜杠', () {
      expect(LlmClient.chatUrl(c('https://api.x/v1')),
          'https://api.x/v1/chat/completions');
      expect(LlmClient.chatUrl(c('https://api.x/v1/')),
          'https://api.x/v1/chat/completions');
      expect(LlmClient.embeddingUrl(c('https://api.x/v1')),
          'https://api.x/v1/embeddings');
      expect(LlmClient.modelsUrl(c('https://api.x/v1')),
          'https://api.x/v1/models');
    });

    test('完整 URL 模式下对话地址原样使用', () {
      expect(LlmClient.chatUrl(c('https://gw.x/proxy/abc', full: true)),
          'https://gw.x/proxy/abc');
    });

    test('完整 URL 模式下能正确推出 embeddings / models', () {
      // 这里曾经有个 bug：只砍掉最后一段路径，得到
      // `https://gw.x/v1/chat/embeddings`。端点后缀是两段
      // （chat/completions），必须整体识别。
      const full = 'https://gw.x/v1/chat/completions';
      expect(LlmClient.embeddingUrl(c(full, full: true)),
          'https://gw.x/v1/embeddings');
      expect(LlmClient.modelsUrl(c(full, full: true)),
          'https://gw.x/v1/models');
      expect(LlmClient.modelsUrl(c('https://gw.x', full: true)),
          'https://gw.x/models');
    });
  });
}
