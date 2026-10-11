/// Someone in the active venue the signed-in user can start a direct message with, from
/// `public.chat_contacts` (names only, never roles).
class ChatContact {
  const ChatContact({required this.userId, this.displayName});

  factory ChatContact.fromJson(Map<String, dynamic> json) => ChatContact(
        userId: json['user_id'] as String,
        displayName: json['display_name'] as String?,
      );

  final String userId;
  final String? displayName;

  String get label {
    final name = displayName?.trim();
    return name == null || name.isEmpty ? 'Team member' : name;
  }
}
