import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';

abstract class ChatRepository {
  Future<List<Conversation>> getConversations({required String venueId});
  Future<List<ChatMessage>> getMessages({required String conversationId, int limit = 50});
  Future<ChatMessage> sendMessage({
    required String conversationId,
    required String text,
    String? attachmentPath,
  });
  Future<void> deleteMessage({required String messageId});
  Future<void> markConversationRead({required String conversationId});
  Future<String> createOrGetDm({required String venueId, required String targetUserId});
}

class SupabaseChatRepository implements ChatRepository {
  SupabaseChatRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Conversation>> getConversations({required String venueId}) async {
    final response = await _client
        .from('conversations')
        .select()
        .eq('venue_id', venueId)
        .order('last_message_at', ascending: false, nullsFirst: false);

    return (response as List<dynamic>)
        .map((row) => Conversation.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<ChatMessage>> getMessages({required String conversationId, int limit = 50}) async {
    final response = await _client
        .from('messages')
        .select()
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .limit(limit);

    return (response as List<dynamic>)
        .map((row) => ChatMessage.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ChatMessage> sendMessage({
    required String conversationId,
    required String text,
    String? attachmentPath,
  }) async {
    final userId = _client.auth.currentUser?.id;
    final conv = await _client.from('conversations').select('venue_id, organization_id').eq('id', conversationId).single();

    final response = await _client
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'venue_id': conv['venue_id'],
          'organization_id': conv['organization_id'],
          'sender_id': userId,
          'text': text,
          if (attachmentPath != null) 'attachment_path': attachmentPath,
        })
        .select()
        .single();

    return ChatMessage.fromJson(response);
  }

  @override
  Future<void> deleteMessage({required String messageId}) async {
    await _client.from('messages').delete().eq('id', messageId);
  }

  @override
  Future<void> markConversationRead({required String conversationId}) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    final conv = await _client.from('conversations').select('venue_id, organization_id').eq('id', conversationId).single();

    await _client.from('conversation_reads').upsert({
      'conversation_id': conversationId,
      'venue_id': conv['venue_id'],
      'organization_id': conv['organization_id'],
      'user_id': userId,
      'read_at': DateTime.now().toIso8601String(),
    }, onConflict: 'conversation_id,user_id');
  }

  @override
  Future<String> createOrGetDm({required String venueId, required String targetUserId}) async {
    final result = await _client.rpc('create_or_get_dm', params: {
      'p_venue_id': venueId,
      'p_target_user_id': targetUserId,
    });
    return result as String;
  }
}
