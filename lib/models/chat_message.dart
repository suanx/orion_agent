/// OpenAI function calling 中的一次工具调用。
class ToolCall {
  final String id;
  final String name;
  final String arguments; // 原始 JSON 字符串

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  Map<String, dynamic> toApiJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'arguments': arguments};

  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        arguments: j['arguments'] as String? ?? '',
      );
}

/// 会话中的一条消息。
class ChatMessage {
  final String id;
  final String role; // system / user / assistant / tool
  final String content;
  final List<ToolCall> toolCalls; // assistant 消息可能携带
  final String? toolCallId; // role == tool 时必填
  final String? toolName;
  final List<String> images; // data URL（base64），user 消息可附带
  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
    this.images = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 转成 OpenAI Chat Completions API 的消息格式。
  /// 带图片的 user 消息用多段 content（text + image_url）。
  Map<String, dynamic> toApiJson() {
    if (role == 'user' && images.isNotEmpty) {
      final parts = <Map<String, dynamic>>[
        if (content.isNotEmpty) {'type': 'text', 'text': content},
        for (final url in images)
          {
            'type': 'image_url',
            'image_url': {'url': url},
          },
      ];
      return {'role': role, 'content': parts};
    }
    final m = <String, dynamic>{'role': role, 'content': content};
    if (toolCalls.isNotEmpty) {
      m['tool_calls'] = toolCalls.map((t) => t.toApiJson()).toList();
    }
    if (role == 'tool') {
      m['tool_call_id'] = toolCallId ?? '';
      if (toolName != null) m['name'] = toolName;
    }
    return m;
  }
}
