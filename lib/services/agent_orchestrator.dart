import 'dart:async';

import 'package:dio/dio.dart';

import 'llm_client.dart';
import 'memory_service.dart';
import 'rag_service.dart';
import '../models/chat_message.dart' show ChatMessage;
import '../models/llm_config.dart';
import 'tools.dart';

/// Agent 运行事件。
abstract class AgentEvent {
  const AgentEvent();
}

/// assistant 的增量文本。
class AgentDelta extends AgentEvent {
  final String delta;
  const AgentDelta(this.delta);
}

/// 状态提示（如“调用工具 calculator …”）。
class AgentStatus extends AgentEvent {
  final String text;
  const AgentStatus(this.text);
}

/// 一次工具调用已完成。
class AgentToolDone extends AgentEvent {
  final String toolName;
  final String result;
  const AgentToolDone(this.toolName, this.result);
}

/// 最终回答（不含工具调用的 assistant 消息）。
class AgentAnswer extends AgentEvent {
  final ChatMessage message;
  const AgentAnswer(this.message);
}

/// 运行失败。
class AgentFailure extends AgentEvent {
  final String message;
  const AgentFailure(this.message);
}

/// Agent 编排器：ReAct 循环（推理 → 工具调用 → 观察结果 → 继续推理）。
class AgentOrchestrator {
  AgentOrchestrator({
    required LlmClient llm,
    required ToolRegistry tools,
    required MemoryService memory,
  })  : _llm = llm,
        _tools = tools,
        _memory = memory;

  static const _maxSteps = 8;

  final LlmClient _llm;
  final ToolRegistry _tools;
  final MemoryService _memory;

  Stream<AgentEvent> run({
    required LlmConfig config,
    required List<ChatMessage> history,
    CancelToken? cancelToken,
    List<RagHit> knowledge = const [],
  }) async* {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt(knowledge)},
      ...history.map((m) => m.toApiJson()),
    ];

    for (var step = 0; step < _maxSteps; step++) {
      ChatMessage? assistant;
      try {
        await for (final ev in _llm.chatStream(
          config: config,
          messages: messages,
          tools: _tools.toOpenAiTools(),
          cancelToken: cancelToken,
        )) {
          if (ev is ContentDelta) {
            yield AgentDelta(ev.delta);
          } else if (ev is FinalMessage) {
            assistant = ev.message;
          }
        }
      } on DioException catch (e) {
        yield AgentFailure(_dioError(e));
        return;
      } catch (e) {
        yield AgentFailure('调用模型失败：$e');
        return;
      }

      if (assistant == null) {
        yield const AgentFailure('模型没有返回内容，请重试。');
        return;
      }

      if (assistant.toolCalls.isEmpty) {
        yield AgentAnswer(assistant);
        return;
      }

      // 有工具调用：执行并把结果回填，进入下一轮
      messages.add(assistant.toApiJson());
      for (final call in assistant.toolCalls) {
        if (call.name.isEmpty) continue;
        yield AgentStatus('正在调用工具 ${call.name} …');
        final result = await _tools.execute(call.name, call.arguments);
        yield AgentToolDone(call.name, result);
        messages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'name': call.name,
          'content': result,
        });
      }
    }
    yield const AgentFailure('已达最大工具调用轮数（$_maxSteps），任务中止。');
  }

  String _systemPrompt(List<RagHit> knowledge) {
    final mem = _memory.memoryPrompt();
    var kb = '';
    if (knowledge.isNotEmpty) {
      final buf = StringBuffer();
      for (var i = 0; i < knowledge.length; i++) {
        buf.writeln('【资料${i + 1}｜来源: ${knowledge[i].docTitle}】');
        buf.writeln(knowledge[i].content);
        buf.writeln();
      }
      kb = '\n以下是从用户知识库检索到的参考资料。回答与这些资料相关的问题时，'
          '优先依据资料内容，并注明来源（如「来源：资料1」）；资料中没有的内容不要编造：\n$buf';
    }
    return '你是 Pocket Agent，一个运行在用户手机上的智能助手。'
        '你可以使用提供的工具来获取实时信息、执行计算、读取网页和检索知识库。'
        '规则：\n'
        '1. 涉及实时信息、精确计算、读取链接时，必须调用工具，不要凭记忆编造。\n'
        '2. 得到工具结果后，用自然语言总结回答，不要原样粘贴原始数据。\n'
        '3. 使用与用户相同的语言回答（默认中文）。\n'
        '4. 回答力求准确、简洁。\n'
        '当前日期：${DateTime.now().year}年${DateTime.now().month}月${DateTime.now().day}日。$mem$kb';
  }

  String _dioError(DioException e) {
    final code = e.response?.statusCode;
    final data = e.response?.data;
    String detail = '';
    if (data is Map && data['error'] is Map) {
      detail = data['error']['message']?.toString() ?? '';
    } else if (data is String && data.length < 300) {
      detail = data;
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '网络超时，请检查网络或稍后重试。';
    }
    return '请求失败（HTTP $code）$detail'.trim();
  }
}
