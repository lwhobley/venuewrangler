import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/chat/application/chat_providers.dart';
import 'package:venuewrangler_mobile/features/chat/data/chat_repository.dart';
import 'package:venuewrangler_mobile/features/chat/domain/chat_contact.dart';
import 'package:venuewrangler_mobile/features/chat/domain/chat_message.dart';
import 'package:venuewrangler_mobile/features/chat/domain/conversation.dart';
import 'package:venuewrangler_mobile/features/chat/presentation/chat_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({
    List<Conversation>? initialConversations,
    List<ChatMessage>? initialMessages,
    this.contacts = const [],
    this.dmPeers = const {},
  })  : conversations = initialConversations ?? [],
        messages = initialMessages ?? [];

  final List<Conversation> conversations;
  final List<ChatMessage> messages;
  final List<ChatContact> contacts;
  final Map<String, String> dmPeers;
  String? dmStartedWith;
  bool sendMessageCalled = false;
  String? lastSentText;

  @override
  Stream<void> watchMessages(String conversationId) => const Stream.empty();

  @override
  Future<List<Conversation>> getConversations({
    required String venueId,
  }) async =>
      conversations;

  @override
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 50,
  }) async =>
      messages.where((m) => m.conversationId == conversationId).toList();

  @override
  Future<ChatMessage> sendMessage({
    required String conversationId,
    required String text,
    String? attachmentPath,
  }) async {
    sendMessageCalled = true;
    lastSentText = text;
    final msg = ChatMessage(
      id: 'msg-new-1',
      organizationId: 'org-1',
      venueId: 'venue-1',
      conversationId: conversationId,
      text: text,
      attachmentPath: attachmentPath,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    messages.add(msg);
    return msg;
  }

  @override
  Future<void> deleteMessage({required String messageId}) async {
    messages.removeWhere((m) => m.id == messageId);
  }

  @override
  Future<void> markConversationRead({required String conversationId}) async {}

  @override
  Future<String> createOrGetDm({
    required String venueId,
    required String targetUserId,
  }) async {
    dmStartedWith = targetUserId;
    return 'conv-dm-1';
  }

  @override
  Future<List<ChatContact>> fetchContacts({required String venueId}) async =>
      contacts;

  @override
  Future<Map<String, String>> fetchDmPeers({
    required List<String> conversationIds,
  }) async =>
      dmPeers;
}

void main() {
  final testVenue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime.now(),
  );

  testWidgets('renders empty state when no conversations exist',
      (tester) async {
    final fakeRepo = _FakeChatRepository(initialConversations: []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          chatRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Team Chat'), findsOneWidget);
    expect(
      find.text('No conversations yet. Tap New message to start one.'),
      findsOneWidget,
    );
  });

  testWidgets('renders conversation list, opens thread and sends message',
      (tester) async {
    final fakeRepo = _FakeChatRepository(
      initialConversations: [
        Conversation(
          id: 'conv-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          type: 'all_staff',
          name: 'All Staff Announcement',
          lastMessageText: 'Shift meeting at 4 PM',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
      initialMessages: [
        ChatMessage(
          id: 'msg-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          conversationId: 'conv-1',
          text: 'Shift meeting at 4 PM',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          chatRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('All Staff Announcement'), findsOneWidget);
    expect(find.text('Shift meeting at 4 PM'), findsOneWidget);

    // Tap to open conversation
    await tester.tap(find.text('All Staff Announcement'));
    await tester.pumpAndSettle();

    expect(find.text('Conversation'), findsOneWidget);
    expect(find.text('Shift meeting at 4 PM'), findsOneWidget);

    // Enter and send message
    await tester.enterText(find.byType(TextField), 'I will be there!');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(fakeRepo.sendMessageCalled, isTrue);
    expect(fakeRepo.lastSentText, 'I will be there!');
  });

  testWidgets('New message lists the team and opens a direct message',
      (tester) async {
    final fakeRepo = _FakeChatRepository(
      contacts: const [
        ChatContact(userId: 'user-mia', displayName: 'Mia Manager'),
        ChatContact(userId: 'user-unnamed'),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          chatRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New message'));
    await tester.pumpAndSettle();

    expect(find.text('Mia Manager'), findsOneWidget);
    expect(find.text('Team member'), findsOneWidget);

    await tester.tap(find.text('Mia Manager'));
    await tester.pumpAndSettle();

    expect(fakeRepo.dmStartedWith, 'user-mia');
    expect(find.text('Conversation'), findsOneWidget);
  });

  testWidgets('a direct message is labelled with the other person',
      (tester) async {
    final fakeRepo = _FakeChatRepository(
      initialConversations: [
        Conversation(
          id: 'conv-dm-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
      contacts: const [
        ChatContact(userId: 'user-mia', displayName: 'Mia Manager'),
      ],
      dmPeers: const {'conv-dm-1': 'user-mia'},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          chatRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mia Manager'), findsOneWidget);
    expect(find.text('Direct Message'), findsNothing);
  });
}
