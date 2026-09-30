/// 一条长期记忆。
class MemoryNote {
  final String id;
  final String text;
  final DateTime createdAt;

  const MemoryNote({required this.id, required this.text, required this.createdAt});

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory MemoryNote.fromJson(Map<String, dynamic> j) => MemoryNote(
        id: j['id'] as String? ?? '',
        text: j['text'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (j['createdAt'] as num?)?.toInt() ?? 0,
        ),
      );
}
