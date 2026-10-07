// ConfigState.activeConfig 降级链单测（v0.2.26-beta 维护版补齐）。
//
// activeConfig 是「对话用哪个提供商」的唯一裁决点，2026-10-06 起语义为：
// activeId（用户在对话页模型浮层最近选中的提供商）优先，其次列表顺序里
// 第一个「已启用且可用」，再退已启用、任意一条。这里的测试锁住整条
// 降级链，防止后续重构悄悄改变选商行为（用户截图反馈过的
// 「新增供应商不显示/选不了」正是这一层出的问题）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/models/llm_config.dart';
import 'package:orion_agent/providers/providers.dart';

LlmConfig cfg(String id, {bool enabled = true, bool ready = true}) {
  return LlmConfig(
    id: id,
    name: '提供商$id',
    baseUrl: ready ? 'https://api.example$id.com/v1' : '',
    apiKey: 'key-$id',
    enabled: enabled,
    models: [ProviderModel(name: 'model-$id')],
  );
}

void main() {
  group('ConfigState.activeConfig 降级链', () {
    test('空配置 → null', () {
      const state = ConfigState(configs: []);
      expect(state.activeConfig, isNull);
      expect(state.usingId, isNull);
    });

    test('没有 activeId → 列表顺序里第一个已启用且可用的', () {
      final state = ConfigState(configs: [cfg('a'), cfg('b')]);
      expect(state.activeConfig!.id, 'a');
    });

    test('activeId 指向第二条 → 用户选择优先于列表顺序', () {
      final state = ConfigState(configs: [cfg('a'), cfg('b')], activeId: 'b');
      expect(state.activeConfig!.id, 'b');
      expect(state.usingId, 'b');
    });

    test('activeId 指向已停用的配置 → 退回第一个已启用且可用', () {
      final state =
          ConfigState(configs: [cfg('a'), cfg('b', enabled: false)], activeId: 'b');
      expect(state.activeConfig!.id, 'a');
    });

    test('activeId 指向未就绪的配置（baseUrl 为空）→ 退回第一个已启用且可用', () {
      final state =
          ConfigState(configs: [cfg('a'), cfg('b', ready: false)], activeId: 'b');
      expect(state.activeConfig!.id, 'a');
    });

    test('都没有 activeId 命中且多条停用 → 跳过停用项取可用项', () {
      final state = ConfigState(configs: [
        cfg('a', enabled: false),
        cfg('b'),
        cfg('c'),
      ]);
      expect(state.activeConfig!.id, 'b');
    });

    test('没有任何一条就绪 → 退回第一个已启用（即使未就绪）', () {
      final state = ConfigState(configs: [
        cfg('a', ready: false),
        cfg('b', ready: false),
      ]);
      expect(state.activeConfig!.id, 'a');
    });

    test('全部停用 → 兜底取第一条（保证老数据不彻底失效）', () {
      final state = ConfigState(configs: [
        cfg('a', enabled: false),
        cfg('b', enabled: false),
      ]);
      expect(state.activeConfig!.id, 'a');
    });

    test('ready 判定：有 baseUrl + 有聊天模型才算就绪', () {
      final noModel = LlmConfig(
          id: 'x', name: 'x', baseUrl: 'https://x.com', apiKey: 'k');
      expect(noModel.ready, isFalse);
      final withModel = LlmConfig(
          id: 'x',
          name: 'x',
          baseUrl: 'https://x.com',
          apiKey: 'k',
          models: const [ProviderModel(name: 'm')]);
      expect(withModel.ready, isTrue);
    });
  });
}
