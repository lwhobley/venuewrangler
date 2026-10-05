import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../data/chat_repository.dart';
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
  return repo.getConversations(venueId: activeVenue.id);
});

final activeConversationIdProvider =
    StateProvider.autoDispose<String?>((ref) => null);

final conversationMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, conversationId) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.getMessages(conversationId: conversationId);
});
