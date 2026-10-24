import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/chat/application/chat_providers.dart';
import 'package:venuewrangler_mobile/features/chat/data/chat_repository.dart';
import 'package:venuewrangler_mobile/features/chat/domain/chat_message.dart';
import 'package:venuewrangler_mobile/features/chat/domain/conversation.dart';
import 'package:venuewrangler_mobile/features/checklists/application/checklists_providers.dart';
import 'package:venuewrangler_mobile/features/checklists/data/checklists_repository.dart';
import 'package:venuewrangler_mobile/features/events/application/events_providers.dart';
import 'package:venuewrangler_mobile/features/events/data/events_repository.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/application/guests_reservations_providers.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/data/guests_reservations_repository.dart';
import 'package:venuewrangler_mobile/features/handover/application/handover_providers.dart';
import 'package:venuewrangler_mobile/features/handover/presentation/handover_screen.dart';
import 'package:venuewrangler_mobile/features/incidents/application/incidents_providers.dart';
import 'package:venuewrangler_mobile/features/incidents/data/incidents_repository.dart';
import 'package:venuewrangler_mobile/features/inventory/application/inventory_providers.dart';
import 'package:venuewrangler_mobile/features/inventory/data/inventory_repository.dart';
import 'package:venuewrangler_mobile/features/schedules/application/schedules_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/data/schedules_repository.dart';
import 'package:venuewrangler_mobile/features/tasks/application/tasks_providers.dart';
import 'package:venuewrangler_mobile/features/tasks/data/tasks_repository.dart';
import 'package:venuewrangler_mobile/features/time_clock/application/time_clock_providers.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/time_clock_repository.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

import 'handover_fixtures.dart';

class _Ai extends Fake implements AiRepository {
  _Ai({this.result, this.error});

  final HandoverSummaryResult? result;
  final Object? error;
  String? lastFacts;
  int calls = 0;

  @override
  Future<HandoverSummaryResult> summarizeHandover({
    required String venueId,
    required String facts,
  }) async {
    calls++;
    lastFacts = facts;
    final e = error;
    if (e != null) throw e;
    return result!;
  }
}

class _Chat extends Fake implements ChatRepository {
  _Chat({this.failSend = false, this.hasAllStaff = true});

  bool failSend;
  final bool hasAllStaff;
  final sent = <({String conversationId, String text})>[];

  @override
  Future<List<Conversation>> getConversations({required String venueId}) async {
    final now = DateTime.utc(2026, 10, 1);
    return [
      Conversation(
        id: 'dm-1',
        organizationId: 'o',
        venueId: venueId,
        createdAt: now,
        updatedAt: now,
      ),
      if (hasAllStaff)
        Conversation(
          id: 'all-1',
          organizationId: 'o',
          venueId: venueId,
          type: 'all_staff',
          createdAt: now,
          updatedAt: now,
        ),
    ];
  }

  @override
  Future<ChatMessage> sendMessage({
    required String conversationId,
    required String text,
    String? attachmentPath,
  }) async {
    if (failSend) throw Exception('offline');
    sent.add((conversationId: conversationId, text: text));
    return ChatMessage.fromJson({
      'id': 'm1',
      'conversation_id': conversationId,
      'organization_id': 'o',
      'venue_id': 'v',
      'sender_id': 'me',
      'text': text,
      'created_at': '2026-10-25T00:30:00Z',
      'updated_at': '2026-10-25T00:30:00Z',
    });
  }
}

final _venue = Venue(
  id: 'v',
  organizationId: 'o',
  name: 'The Barn',
  createdAt: DateTime.utc(2026),
);

Future<void> _pump(
  WidgetTester tester, {
  required _Ai ai,
  _Chat? chat,
  bool manager = true,
}) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeVenueProvider.overrideWith((ref) => _venue),
        canManageActiveVenueProvider.overrideWith((ref) async => manager),
        handoverFactsProvider.overrideWith((ref) async => busyFacts()),
        aiRepositoryProvider.overrideWithValue(ai),
        chatRepositoryProvider.overrideWithValue(chat ?? _Chat()),
      ],
      child: const MaterialApp(home: HandoverScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

TextField _noteField(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first);

void main() {
  const aiResult = HandoverSummaryResult(
    summary: 'Busy night with one open incident.',
    sections: [
      HandoverSection(
        title: 'Clock exceptions',
        items: ['staff_1 never clocked out.'],
      ),
    ],
  );

  testWidgets('shows the deterministic facts and a starting note',
      (tester) async {
    await _pump(tester, ai: _Ai(result: aiResult));

    expect(find.text('Shift handover'), findsOneWidget);
    expect(find.textContaining('[HIGH] Fight at the bar'), findsWidgets);
    expect(find.text('• Tito\'s Vodka: out'), findsOneWidget);
    expect(find.text('• Closing checklist'), findsOneWidget);
    final note = _noteField(tester).controller!.text;
    expect(note, startsWith('Shift handover - The Barn'));
    expect(note, contains('Maya Lopez: still clocked in'));
  });

  testWidgets('AI draft replaces the note, names restored, payload has none',
      (tester) async {
    final ai = _Ai(result: aiResult);
    await _pump(tester, ai: ai);

    await tester.tap(find.text('Write with AI'));
    await tester.pumpAndSettle();

    final note = _noteField(tester).controller!.text;
    expect(note, contains('Busy night with one open incident.'));
    expect(note, contains('- Maya Lopez never clocked out.'));
    expect(note, isNot(contains('staff_1')));
    expect(ai.lastFacts, isNot(contains('Maya')));
    expect(ai.lastFacts, contains('staff_1'));
    expect(find.text('Redraft with AI'), findsOneWidget);
  });

  testWidgets('AI disabled: shows the message and keeps the facts note',
      (tester) async {
    final ai = _Ai(
      error: const AiUnavailableError(
        'AI features are turned off for this organization.',
      ),
    );
    await _pump(tester, ai: ai);
    final before = _noteField(tester).controller!.text;

    await tester.tap(find.text('Write with AI'));
    await tester.pumpAndSettle();

    expect(
      find.text('AI features are turned off for this organization.'),
      findsOneWidget,
    );
    expect(_noteField(tester).controller!.text, before);
    expect(find.textContaining('[HIGH] Fight at the bar'), findsWidgets);
    final copy = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Copy'),
        matching: find.byWidgetPredicate((w) => w is OutlinedButton),
      ),
    );
    expect(copy.onPressed, isNotNull);
  });

  testWidgets('an empty AI result is reported and the note is kept',
      (tester) async {
    final ai =
        _Ai(result: const HandoverSummaryResult(summary: '', sections: []));
    await _pump(tester, ai: ai);
    final before = _noteField(tester).controller!.text;

    await tester.tap(find.text('Write with AI'));
    await tester.pumpAndSettle();

    expect(find.textContaining('returned an empty note'), findsOneWidget);
    expect(_noteField(tester).controller!.text, before);
  });

  testWidgets('redrafting asks before discarding the manager\'s edits',
      (tester) async {
    final ai = _Ai(result: aiResult);
    await _pump(tester, ai: ai);

    await tester.enterText(find.byType(TextField).first, 'My own note');
    await tester.tap(find.text('Write with AI'));
    await tester.pumpAndSettle();
    expect(find.text('Replace your edits?'), findsOneWidget);

    await tester.tap(find.text('Keep my text'));
    await tester.pumpAndSettle();
    expect(ai.calls, 0);
    expect(_noteField(tester).controller!.text, 'My own note');

    await tester.tap(find.text('Write with AI'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(ai.calls, 1);
    expect(_noteField(tester).controller!.text, contains('Busy night'));
  });

  testWidgets('Copy puts the edited note on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _pump(tester, ai: _Ai(result: aiResult));

    await tester.enterText(find.byType(TextField).first, '  Edited note  ');
    await tester.ensureVisible(find.text('Copy'));
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, 'Edited note');
  });

  testWidgets('posting needs confirmation, then goes to All Staff',
      (tester) async {
    final chat = _Chat();
    await _pump(tester, ai: _Ai(result: aiResult), chat: chat);
    await tester.enterText(find.byType(TextField).first, 'Edited note');

    await tester.ensureVisible(find.text('Post to team chat (All Staff)'));
    await tester.tap(find.text('Post to team chat (All Staff)'));
    await tester.pumpAndSettle();
    expect(find.text('Post to All Staff?'), findsOneWidget);
    expect(chat.sent, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(chat.sent, isEmpty);

    await tester.tap(find.text('Post to team chat (All Staff)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(chat.sent.single.conversationId, 'all-1');
    expect(chat.sent.single.text, 'Edited note');
    expect(find.text('Posted to All Staff.'), findsOneWidget);
  });

  testWidgets('a failed post keeps the note and says so', (tester) async {
    final chat = _Chat(failSend: true);
    await _pump(tester, ai: _Ai(result: aiResult), chat: chat);
    await tester.enterText(find.byType(TextField).first, 'Edited note');

    await tester.ensureVisible(find.text('Post to team chat (All Staff)'));
    await tester.tap(find.text('Post to team chat (All Staff)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not post to team chat'), findsOneWidget);
    expect(_noteField(tester).controller!.text, 'Edited note');

    // Retrying works once the connection is back.
    chat.failSend = false;
    await tester.tap(find.text('Post to team chat (All Staff)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();
    expect(chat.sent.single.text, 'Edited note');
  });

  testWidgets('no All Staff chat is explained', (tester) async {
    final chat = _Chat(hasAllStaff: false);
    await _pump(tester, ai: _Ai(result: aiResult), chat: chat);

    await tester.ensureVisible(find.text('Post to team chat (All Staff)'));
    await tester.tap(find.text('Post to team chat (All Staff)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(find.text('This venue has no All Staff chat.'), findsOneWidget);
  });

  testWidgets('non-managers cannot use handover', (tester) async {
    await _pump(tester, ai: _Ai(result: aiResult), manager: false);
    expect(find.text('Shift handover is for managers.'), findsOneWidget);
    expect(find.text('Write with AI'), findsNothing);
  });

  group('handoverFactsProvider', () {
    test('sources that fail become unavailable sections', () async {
      final container = ProviderContainer(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _venue),
          handoverNowProvider.overrideWithValue(() => handoverNow),
          incidentsRepositoryProvider.overrideWithValue(_BrokenIncidents()),
          inventoryRepositoryProvider.overrideWithValue(_BrokenInventory()),
          tasksRepositoryProvider.overrideWithValue(_BrokenTasks()),
          checklistsRepositoryProvider.overrideWithValue(_BrokenChecklists()),
          timeClockRepositoryProvider.overrideWithValue(_BrokenClock()),
          schedulesRepositoryProvider.overrideWithValue(_BrokenSchedules()),
          eventsRepositoryProvider.overrideWithValue(_BrokenEvents()),
          guestsReservationsRepositoryProvider
              .overrideWithValue(_BrokenReservations()),
          scheduleRosterForVenueProvider('v').overrideWith(
            (ref) async => const [
              RosterMember(userId: 'u1', role: 'staff', displayName: 'Maya'),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);

      final facts = await container.read(handoverFactsProvider.future);
      expect(facts.unavailable, hasLength(7));
      expect(facts.staffNames, {'u1': 'Maya'});
    });
  });
}

class _BrokenIncidents extends Fake implements IncidentsRepository {}

class _BrokenInventory extends Fake implements InventoryRepository {}

class _BrokenTasks extends Fake implements TasksRepository {}

class _BrokenChecklists extends Fake implements ChecklistsRepository {}

class _BrokenClock extends Fake implements TimeClockRepository {}

class _BrokenSchedules extends Fake implements SchedulesRepository {}

class _BrokenEvents extends Fake implements EventsRepository {}

class _BrokenReservations extends Fake
    implements GuestsReservationsRepository {}
