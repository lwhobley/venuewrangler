class Conversation {
  const Conversation({
    required this.id,
    required this.organizationId,
    required this.venueId,
    this.type = 'dm',
    this.name,
    this.isSystem = false,
    this.lastMessageAt,
    this.lastMessageText,
    required this.createdAt,
    required this.updatedAt,
    this.peerName,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      type: json['type'] as String? ?? 'dm',
      name: json['name'] as String?,
      isSystem: json['is_system'] as bool? ?? false,
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'] as String)
          : null,
      lastMessageText: json['last_message_text'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  final String id;
  final String organizationId;
  final String venueId;
  final String type;
  final String? name;
  final bool isSystem;
  final DateTime? lastMessageAt;
  final String? lastMessageText;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// For a direct message, the other person's name (resolved by the list provider).
  final String? peerName;

  Conversation withPeerName(String? peerName) => Conversation(
        id: id,
        organizationId: organizationId,
        venueId: venueId,
        type: type,
        name: name,
        isSystem: isSystem,
        lastMessageAt: lastMessageAt,
        lastMessageText: lastMessageText,
        createdAt: createdAt,
        updatedAt: updatedAt,
        peerName: peerName,
      );

  String get displayName =>
      name ??
      (type == 'all_staff' ? 'All Staff' : (peerName ?? 'Direct Message'));
}
