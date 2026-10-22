import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../data/chat_repository.dart';
import '../domain/chat_contact.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseChatRepository(client);
});

final conversationsListProvider =
    FutureProvider.autoDispose<List<Conversation>>((ref) async {
  final activeVenue = ref.watch(activeVenueProvider);
  if (activeVenue == null) return [];

  final repo = ref.watch(chatRepositoryProvider);
  final conversations = await repo.getConversations(venueId: activeVenue.id);

  // Label each direct message with the other person's name. Best effort: if the names can't
  // be loaded the list still shows, with the generic label.
  final dmIds = [
    for (final c in conversations)
      if (c.type == 'dm') c.id,
  ];
  if (dmIds.isEmpty) return conversations;
  try {
    final peers = await repo.fetchDmPeers(conversationIds: dmIds);
    final contacts = await repo.fetchContacts(venueId: activeVenue.id);
    final names = {for (final c in contacts) c.userId: c.label};
    return [
      for (final c in conversations)
        c.type == 'dm' && peers[c.id] != null
            ? c.withPeerName(names[peers[c.id]] ?? 'Former team member')
            : c,
    ];
  } catch (_) {
    return conversations;
  }
});

final chatContactsProvider =
    FutureProvider.autoDispose<List<ChatContact>>((ref) async {
  final activeVenue = ref.watch(activeVenueProvider);
  if (activeVenue == null) return [];
  return ref
      .watch(chatRepositoryProvider)
      .fetchContacts(venueId: activeVenue.id);
});

/// The active venue's team by user id, for labelling who sent each chat message. The caller
/// isn't in `chat_contacts`, which is fine: their own messages are never labelled.
final chatSenderNamesProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final contacts = await ref.watch(chatContactsProvider.future);
  return {for (final c in contacts) c.userId: c.label};
});

final activeConversationIdProvider =
    StateProvider.autoDispose<String?>((ref) => null);

final conversationMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, conversationId) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.getMessages(conversationId: conversationId);
});
