/// 一条长期记忆。
class MemoryNote {
  final String id;
  final String text;
  final DateTime createdAt;

  const MemoryNote({required this.id, required this.text, required this.createdAt});
}
