class ChatMessage {
  final String id;
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  bool get isUser => role == 'user';
}

class ChatSession {
  final String id;
  final String title;
  final int messageCount;
  final DateTime createdAt;
  final DateTime? lastMessageAt;
  final List<ChatMessage> history;

  ChatSession({
    required this.id,
    required this.title,
    required this.messageCount,
    required this.createdAt,
    this.lastMessageAt,
    required this.history,
  });

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final historyJson = json['history'] as List<dynamic>? ?? [];
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Chat',
      messageCount: json['message_count'] as int? ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'] as String)
          : null,
      history: historyJson
          .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}
