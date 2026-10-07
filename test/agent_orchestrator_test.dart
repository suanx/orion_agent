// AgentOrchestrator 主循环单测（v0.2.26-beta 维护版补齐，评估项 M4）。
//
// 之前编排器零测试覆盖，回归全靠人肉。这里用 noSuchMethod 假体隔离
// LlmClient / ToolRegistry / MemoryService（均为具体类，假体只实现
// 编排器真正触达的成员），锁住四个关键行为：
//   1. 无工具调用 → 直接 AgentAnswer
//   2. 空名 tool_call → 回填错误结果继续（P2-11：否则下一轮被服务端 400）
//   3. 连续重复调用同一工具（同名同参 3 次）→ 提前中止
//   4. 耗尽 _maxSteps=8 轮 → 交付 lastVisible 进展而非全部丢弃
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orion_agent/models/chat_message.dart';
import 'package:orion_agent/models/llm_config.dart';
import 'package:orion_agent/services/agent_orchestrator.dart';
import 'package:orion_agent/services/llm_client.dart';
import 'package:orion_agent/services/memory_service.dart';
import 'package:orion_agent/services/tools.dart';

/// 按剧本逐轮返回 assistant 消息的假 LLM。
/// 剧本耗尽后重复最后一条（便于构造"永远调工具"的场景）。
class FakeLlm implements LlmClient {
  FakeLlm(this.scripted);

  final List<ChatMessage> scripted;
  int call = 0;

  /// 每次 chatStream 收到的 messages 快照（验证工具结果回填用）。
  final List<List<Map<String, dynamic>>> seenMessages = [];

  @override
  Stream<LlmEvent> chatStream({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    dynamic cancelToken,
    bool thinking = false,
    String reasoningEffort = 'medium',
  }) async* {
    seenMessages.add(List.of(messages));
    final idx = call < scripted.length ? call : scripted.length - 1;
    call++;
    yield FinalMessage(scripted[idx]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeTools implements ToolRegistry {
  @override
  List<Map<String, dynamic>> toOpenAiTools() => const [];

  @override
  Future<String> execute(String name, String rawArguments) async =>
      'ok:$name:$rawArguments';

  @override
  List<Tool> get all => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeMemory implements MemoryService {
  @override
  String memoryPrompt() => '';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ChatMessage assistant(String content, [List<ToolCall> toolCalls = const []]) =>
    ChatMessage(id: 'a${content.hashCode}', role: 'assistant',
        content: content, toolCalls: toolCalls);

AgentOrchestrator buildOrchestrator(LlmClient llm) => AgentOrchestrator(
      llm: llm,
      tools: FakeTools(),
      memory: FakeMemory(),
    );

/// 按剧本逐轮执行流工厂的假 LLM：每个工厂是「一轮请求」的完整行为
/// （可以先吐 delta 再抛错，模拟流中途断；也可以直接抛，模拟首包失败）。
class ScriptedLlm implements LlmClient {
  ScriptedLlm(this.rounds);

  final List<Stream<LlmEvent> Function()> rounds;
  int call = 0;

  @override
  Stream<LlmEvent> chatStream({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    dynamic cancelToken,
    bool thinking = false,
    String reasoningEffort = 'medium',
  }) async* {
    final idx = call < rounds.length ? call : rounds.length - 1;
    call++;
    yield* rounds[idx]();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 连接被重置（基站切换/NAT 超时的典型异常形态）。
Object connectionReset() => DioException(
      requestOptions: RequestOptions(path: '/chat/completions'),
      type: DioExceptionType.connectionError,
      error: const SocketException('connection reset'),
    );

final config = LlmConfig(
  id: 't',
  name: '测试',
  baseUrl: 'https://api.test/v1',
  apiKey: 'key',
  models: const [ProviderModel(name: 'test-model')],
);

void main() {
  final history = [ChatMessage(id: 'u1', role: 'user', content: '问题')];

  test('无工具调用：直接产出 AgentAnswer，无失败事件', () async {
    final llm = FakeLlm([assistant('你好，答案是 42')]);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    expect(events.whereType<AgentFailure>(), isEmpty);
    final answers = events.whereType<AgentAnswer>().toList();
    expect(answers, hasLength(1));
    expect(answers.single.message.content, '你好，答案是 42');
  });

  test('空内容且无工具调用 → 明确失败而不是落库空消息', () async {
    final llm = FakeLlm([assistant('  ')]);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    expect(events.whereType<AgentAnswer>(), isEmpty);
    expect(events.whereType<AgentFailure>().single.message, contains('空内容'));
  });

  test('空名 tool_call：回填错误结果继续，下一轮请求带上 tool 消息', () async {
    final llm = FakeLlm([
      assistant('', const [ToolCall(id: 'call_1', name: '', arguments: '{}')]),
      assistant('完成'),
    ]);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    // 不因空名 tool_call 而终止：仍然拿到最终回答
    expect(events.whereType<AgentAnswer>().single.message.content, '完成');
    // 对未命名工具产出了 ToolDone 事件
    final done = events.whereType<AgentToolDone>().single;
    expect(done.toolName, '(未命名工具)');
    expect(done.result, contains('缺少函数名'));
    // 第二轮请求里 assistant 的 tool_call 后面紧跟匹配的 tool 回复
    final secondRound = llm.seenMessages[1];
    final toolMsg = secondRound.firstWhere((m) => m['role'] == 'tool');
    expect(toolMsg['tool_call_id'], 'call_1');
    expect(toolMsg['content'], contains('缺少函数名'));
  });

  test('同名同参连续 3 次 → 提前中止，避免空转', () async {
    ChatMessage repeat() => assistant('', const [
          ToolCall(id: 'c', name: 'web_search', arguments: '{"q":"x"}'),
        ]);
    final llm = FakeLlm([repeat()]);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    expect(events.whereType<AgentAnswer>(), isEmpty);
    final failure = events.whereType<AgentFailure>().single.message;
    expect(failure, contains('重复调用同一个工具'));
    // 3 次重复在第 3 轮被拦截
    expect(llm.call, lessThanOrEqualTo(3));
  });

  test('工具调用轮数无上限：10 轮后仍正常收尾（原上限 8 轮）', () async {
    final scripted = <ChatMessage>[
      for (var i = 1; i <= 10; i++)
        assistant('', [
          ToolCall(id: 'c$i', name: 'web_search', arguments: '{"q":"$i"}'),
        ]),
      assistant('10 轮调研完成'),
    ];
    final llm = FakeLlm(scripted);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    expect(events.whereType<AgentFailure>(), isEmpty,
        reason: '超过原 8 轮上限后不得中止');
    final answers = events.whereType<AgentAnswer>().toList();
    expect(answers, hasLength(1));
    expect(answers.single.message.content, '10 轮调研完成');
    expect(llm.call, 11, reason: '10 轮工具调用 + 1 轮最终回答');
    // 工具结果按 tool_call_id 逐轮回填：第 r 次 LLM 调用时已累积 r 条
    // tool 回复（每轮恰好回填一条，不残留未回填调用）
    for (var r = 1; r < llm.seenMessages.length; r++) {
      final toolMsgs =
          llm.seenMessages[r].where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs, hasLength(r), reason: 'round $r');
    }
  });

  test('每轮工具结果按 tool_call_id 回填（多轮循环不残留未回填调用）', () async {
    final scripted = <ChatMessage>[
      assistant('', const [ToolCall(id: 'c1', name: 'calculator', arguments: '{"e":"1+1"}')]),
      assistant('等于 2'),
    ];
    final llm = FakeLlm(scripted);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    expect(events.whereType<AgentFailure>(), isEmpty);
    final toolMsgs =
        llm.seenMessages[1].where((m) => m['role'] == 'tool').toList();
    expect(toolMsgs, hasLength(1));
    expect(toolMsgs.single['tool_call_id'], 'c1');
    expect(toolMsgs.single['content'], 'ok:calculator:{"e":"1+1"}');
  });

  setUp(() {
    // 重试退避置 0，测试不等待真实秒数
    AgentOrchestrator.retryBackoffBaseSeconds = 0;
  });

  tearDown(() {
    AgentOrchestrator.retryBackoffBaseSeconds = 2;
  });

  test('首包前断流：自动整轮重发并成功，无 Restart 事件（UI 无感知）', () async {
    final llm = ScriptedLlm([
      () => throw connectionReset(),
      () async* {
        yield FinalMessage(assistant('恢复后完成'));
      },
    ]);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    expect(events.whereType<AgentFailure>(), isEmpty);
    expect(events.whereType<AgentRoundRestart>(), isEmpty,
        reason: '本轮没吐过字，重试不需要 UI 清气泡');
    expect(events.whereType<AgentStatus>().any((s) => s.text.contains('自动重试')),
        isTrue, reason: '重试动作要在「正在思考」步骤里可见');
    expect(events.whereType<AgentAnswer>().single.message.content, '恢复后完成');
    expect(llm.call, 2);
  });

  test('流中途断（已吐字）：重试前发 AgentRoundRestart，最终回答不拼接残句', () async {
    final llm = ScriptedLlm([
      () async* {
        yield ContentDelta('半句');
        throw connectionReset();
      },
      () async* {
        yield FinalMessage(assistant('完整回答'));
      },
    ]);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    expect(events.whereType<AgentFailure>(), isEmpty);
    final restarts = events.whereType<AgentRoundRestart>().toList();
    expect(restarts, hasLength(1), reason: '吐过字的重试必须通知 UI 清残缺气泡');
    expect(restarts.single.reasoningPrefix, '');
    final deltas = events.whereType<AgentDelta>().map((e) => e.delta).toList();
    expect(deltas, contains('半句'),
        reason: '断前的残句确实到达过 UI（清理由 AgentRoundRestart 消费方负责）');
    expect(events.whereType<AgentAnswer>().single.message.content, '完整回答');
  });

  test('非临时性错误（如余额不足）不重试，立即失败', () async {
    final llm = ScriptedLlm([
      () async* {
        throw Exception('模型服务返回错误：余额不足');
      },
    ]);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    expect(llm.call, 1, reason: '明确的服务端错误重试没有意义');
    expect(events.whereType<AgentRoundRestart>(), isEmpty);
    final failures = events.whereType<AgentFailure>().toList();
    expect(failures, hasLength(1));
    expect(failures.single.message, contains('余额不足'));
  });

  test('多轮任务重试耗尽：已完成轮次的 lead 不丢弃，随部分回答落库', () async {
    final llm = ScriptedLlm([
      () async* {
        yield FinalMessage(assistant('第一轮进展', [
          ToolCall(id: 'c1', name: 'web_search', arguments: '{"q":"x"}'),
        ]));
      },
      () => throw connectionReset(),
      () => throw connectionReset(),
    ]);
    final events =
        await buildOrchestrator(llm).run(config: config, history: history).toList();

    // 重试按轮计：第 1 轮 1 次成功；第 2 轮 1 次初始 + 2 次重试 = 3 次
    expect(llm.call, 4, reason: '轮 1 一次成功 + 轮 2 初始一次 + 重试两次');
    final answers = events.whereType<AgentAnswer>().toList();
    expect(answers, hasLength(1), reason: 'lead 非空时必须保住已完成部分');
    expect(answers.single.message.content, contains('第一轮进展'));
    expect(answers.single.message.content, contains('网络中断'));
    expect(events.whereType<AgentFailure>(), hasLength(1),
        reason: '部分回答照常保存的同时，错误提示也要弹');
  });
}

