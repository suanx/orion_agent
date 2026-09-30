import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/chat_message.dart';
import '../models/llm_config.dart';

/// LLM 流式事件。
abstract class LlmEvent {
  const LlmEvent();
}

/// 一段增量文本。
class ContentDelta extends LlmEvent {
  final String delta;
  const ContentDelta(this.delta);
}

/// 一轮响应结束后的完整 assistant 消息（可能携带工具调用）。
class FinalMessage extends LlmEvent {
  final ChatMessage message;
  const FinalMessage(this.message);
}

class _ToolCallAcc {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

/// OpenAI 兼容协议的流式客户端（SSE）。
class LlmClient {
  LlmClient(this._dio);

  final Dio _dio;

  Stream<LlmEvent> chatStream({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async* {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    final url = '$base/chat/completions';

    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'temperature': config.temperature,
      'stream': true,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
    };

    final resp = await _dio.post<ResponseBody>(
      url,
      data: body,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
      ),
    );

    final contentBuf = StringBuffer();
    final toolAcc = <int, _ToolCallAcc>{};

    final lines = resp.data!.stream.cast<List<int>>().transform(utf8.decoder).transform(
          const LineSplitter(),
        );

    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') break;

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue; // 跳过无法解析的行
      }

      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;
      final delta = choice['delta'] as Map<String, dynamic>? ?? const {};

      final c = delta['content'];
      if (c is String && c.isNotEmpty) {
        contentBuf.write(c);
        yield ContentDelta(c);
      }

      final tcs = delta['tool_calls'] as List?;
      if (tcs != null) {
        for (final tc in tcs) {
          if (tc is! Map<String, dynamic>) continue;
          final idx = (tc['index'] as num?)?.toInt() ?? 0;
          final acc = toolAcc.putIfAbsent(idx, () => _ToolCallAcc());
          if (tc['id'] is String && (acc.id == null || acc.id!.isEmpty)) {
            acc.id = tc['id'] as String;
          }
          final fn = tc['function'];
          if (fn is Map<String, dynamic>) {
            final n = fn['name'];
            if (n is String && n.isNotEmpty) {
              acc.name = acc.name == null ? n : acc.name! + n;
            }
            final a = fn['arguments'];
            if (a is String) acc.arguments.write(a);
          }
        }
      }
    }

    final entries = toolAcc.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final finalMsg = ChatMessage(
      id: 'asst_${DateTime.now().millisecondsSinceEpoch}',
      role: 'assistant',
      content: contentBuf.toString(),
      toolCalls: entries
          .map((e) => ToolCall(
                id: e.value.id ?? 'call_${e.key}',
                name: e.value.name ?? '',
                arguments: e.value.arguments.toString(),
              ))
          .toList(),
    );
    yield FinalMessage(finalMsg);
  }
}
