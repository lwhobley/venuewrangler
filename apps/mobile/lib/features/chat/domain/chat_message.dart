class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.organizationId,
    required this.venueId,
    required this.conversationId,
    this.senderId,
    this.text,
    this.attachmentPath,
    this.reactions = const {},
    required this.createdAt,
    required this.updatedAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String?,
      text: json['text'] as String?,
      attachmentPath: json['attachment_path'] as String?,
      reactions: (json['reactions'] as Map<String, dynamic>?) ?? const {},
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  final String id;
  final String organizationId;
  final String venueId;
  final String conversationId;
  final String? senderId;
  final String? text;
  final String? attachmentPath;
  final Map<String, dynamic> reactions;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasAttachment => attachmentPath != null && attachmentPath!.isNotEmpty;
}
