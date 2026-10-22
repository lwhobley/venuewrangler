import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
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
          currentUserIdProvider.overrideWithValue('user-me'),
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
          currentUserIdProvider.overrideWithValue('user-me'),
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

    expect(find.text('All Staff Announcement'), findsOneWidget);
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
          currentUserIdProvider.overrideWithValue('user-me'),
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
          currentUserIdProvider.overrideWithValue('user-me'),
          chatRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mia Manager'), findsOneWidget);
    expect(find.text('Direct Message'), findsNothing);
  });

  group('message thread', () {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));

    ChatMessage message(
      String id,
      String conversationId,
      String? senderId,
      String text,
      DateTime at,
    ) =>
        ChatMessage(
          id: id,
          organizationId: 'org-1',
          venueId: 'venue-1',
          conversationId: conversationId,
          senderId: senderId,
          text: text,
          createdAt: at,
          updatedAt: at,
        );

    Conversation conversation(String id, String type) => Conversation(
          id: id,
          organizationId: 'org-1',
          venueId: 'venue-1',
          type: type,
          createdAt: now,
          updatedAt: now,
        );

    Future<void> openThread(
      WidgetTester tester,
      _FakeChatRepository repo,
      String title,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeVenueProvider.overrideWith((ref) => testVenue),
            currentUserIdProvider.overrideWithValue('user-me'),
            chatRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: ChatScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    double bubbleLeft(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dx;

    testWidgets(
        'a group thread names other senders, sets own replies apart and '
        'shows times by day', (tester) async {
      final repo = _FakeChatRepository(
        initialConversations: [conversation('conv-all', 'all_staff')],
        initialMessages: [
          message('m0', 'conv-all', 'user-gone', 'Old news', yesterday),
          message('m1', 'conv-all', 'user-mia', 'Who can cover Sunday?', now),
          message('m2', 'conv-all', 'user-mia', 'Brunch shift', now),
          message('m3', 'conv-all', 'user-me', 'I can do it', now),
        ],
        contacts: const [
          ChatContact(userId: 'user-mia', displayName: 'Mia Manager'),
        ],
      );

      await openThread(tester, repo, 'All Staff');

      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      // Mia's two messages in a row carry her name once; a sender who has left the venue
      // is still identified as such; the signed-in user's own reply is unlabelled.
      expect(find.text('Mia Manager'), findsOneWidget);
      expect(find.text('Former team member'), findsOneWidget);
      expect(find.text('You'), findsNothing);

      // Own replies sit on the right, other people's on the left.
      expect(
        bubbleLeft(tester, 'I can do it'),
        greaterThan(bubbleLeft(tester, 'Brunch shift')),
      );
      final ownBubble = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('I can do it'),
              matching: find.byType(Container),
            )
            .first,
      );
      final otherBubble = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('Brunch shift'),
              matching: find.byType(Container),
            )
            .first,
      );
      final scheme =
          Theme.of(tester.element(find.text('I can do it'))).colorScheme;
      expect(
        (ownBubble.decoration! as BoxDecoration).color,
        scheme.primaryContainer,
      );
      expect(
        (otherBubble.decoration! as BoxDecoration).color,
        scheme.surfaceContainerHighest,
      );

      // Every message shows when it was sent (yesterday's was at the same time of day).
      final context = tester.element(find.text('I can do it'));
      final time = MaterialLocalizations.of(context)
          .formatTimeOfDay(TimeOfDay.fromDateTime(now));
      expect(find.text(time), findsNWidgets(4));
    });

    testWidgets('a direct message shows whose reply is whose without names',
        (tester) async {
      final repo = _FakeChatRepository(
        initialConversations: [conversation('conv-dm', 'dm')],
        initialMessages: [
          message(
            'm1',
            'conv-dm',
            'user-mia',
            'Any chance you can stay until 11 on Friday?',
            now,
          ),
          message('m2', 'conv-dm', 'user-me', 'Yes, I can do that.', now),
        ],
        contacts: const [
          ChatContact(userId: 'user-mia', displayName: 'Mia Manager'),
        ],
        dmPeers: const {'conv-dm': 'user-mia'},
      );

      await openThread(tester, repo, 'Mia Manager');

      // The title names the other person; the bubbles themselves don't repeat it.
      expect(find.text('Mia Manager'), findsOneWidget);
      expect(
        bubbleLeft(tester, 'Yes, I can do that.'),
        greaterThan(
          bubbleLeft(tester, 'Any chance you can stay until 11 on Friday?'),
        ),
      );
    });
  });
}
