import 'chat_message.dart';

/// 一个会话（多轮对话）。
class ChatSession {
  final String id;
  String title;
  final List<ChatMessage> messages;
  final DateTime createdAt;
  DateTime updatedAt;

  ChatSession({
    required this.id,
    this.title = '新对话',
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });
}
