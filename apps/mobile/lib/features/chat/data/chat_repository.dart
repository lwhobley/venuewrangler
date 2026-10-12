import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/chat_contact.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';

abstract class ChatRepository {
  Stream<void> watchMessages(String conversationId);
  Future<List<Conversation>> getConversations({required String venueId});
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 50,
  });
  Future<ChatMessage> sendMessage({
    required String conversationId,
    required String text,
    String? attachmentPath,
  });
  Future<void> deleteMessage({required String messageId});
  Future<void> markConversationRead({required String conversationId});
  Future<String> createOrGetDm({
    required String venueId,
    required String targetUserId,
  });

  /// People in the venue the signed-in user can message (excludes the user).
  Future<List<ChatContact>> fetchContacts({required String venueId});

  /// For each direct-message conversation, the other participant's user id.
  Future<Map<String, String>> fetchDmPeers({
    required List<String> conversationIds,
  });
}

class SupabaseChatRepository implements ChatRepository {
  SupabaseChatRepository(this._client);

  final SupabaseClient _client;

  @override
  Stream<void> watchMessages(String conversationId) {
    late final RealtimeChannel channel;
    late final StreamController<void> controller;
    controller = StreamController<void>(
      onListen: () {
        channel = _client
            .channel('messages:$conversationId')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'messages',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'conversation_id',
                value: conversationId,
              ),
              callback: (_) {
                if (!controller.isClosed) controller.add(null);
              },
            )
            .subscribe();
      },
      onCancel: () {
        unawaited(_client.removeChannel(channel));
      },
    );
    return controller.stream;
  }

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
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 50,
  }) async {
    final response = await _client
        .from('messages')
        .select()
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: false)
        .limit(limit);

    return (response as List<dynamic>)
        .reversed
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
    final conv = await _client
        .from('conversations')
        .select('venue_id, organization_id')
        .eq('id', conversationId)
        .single();

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

    final conv = await _client
        .from('conversations')
        .select('venue_id, organization_id')
        .eq('id', conversationId)
        .single();

    await _client.from('conversation_reads').upsert(
      {
        'conversation_id': conversationId,
        'venue_id': conv['venue_id'],
        'organization_id': conv['organization_id'],
        'user_id': userId,
        'read_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'conversation_id,user_id',
    );
  }

  @override
  Future<String> createOrGetDm({
    required String venueId,
    required String targetUserId,
  }) async {
    final result = await _client.rpc(
      'create_or_get_dm',
      params: {
        'p_venue_id': venueId,
        'p_target_user_id': targetUserId,
      },
    );
    return result as String;
  }

  @override
  Future<List<ChatContact>> fetchContacts({required String venueId}) async {
    final rows = await _client.rpc(
      'chat_contacts',
      params: {'p_venue_id': venueId},
    ) as List<dynamic>;
    return rows
        .cast<Map<String, dynamic>>()
        .map(ChatContact.fromJson)
        .toList(growable: false);
  }

  @override
  Future<Map<String, String>> fetchDmPeers({
    required List<String> conversationIds,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || conversationIds.isEmpty) return const {};
    final rows = await _client
        .from('conversation_members')
        .select('conversation_id, user_id')
        .inFilter('conversation_id', conversationIds)
        .neq('user_id', userId);
    return {
      for (final row in rows)
        row['conversation_id'] as String: row['user_id'] as String,
    };
  }
}
