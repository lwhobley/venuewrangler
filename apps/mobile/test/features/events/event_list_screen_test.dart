import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/events/application/events_providers.dart';
import 'package:venuewrangler_mobile/features/events/data/events_repository.dart';
import 'package:venuewrangler_mobile/features/events/domain/event.dart';
import 'package:venuewrangler_mobile/features/events/presentation/event_details_sheet.dart';
import 'package:venuewrangler_mobile/features/events/presentation/event_list_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeEventsRepository implements EventsRepository {
  _FakeEventsRepository(this.events);

  final List<VenueEvent> events;
  Object? failNextCreate;
  final created = <({String name, String? notes})>[];

  @override
  Future<List<VenueEvent>> fetchEventsForVenue(String venueId) async => events;

  @override
  Future<void> createEvent({
    required String venueId,
    required String name,
    required DateTime startTime,
    required DateTime endTime,
    String? notes,
  }) async {
    final error = failNextCreate;
    failNextCreate = null;
    if (error != null) throw error;
    created.add((name: name, notes: notes));
  }

  @override
  Future<void> updateStatus(String eventId, EventStatus status) async {}

  @override
  Future<void> deleteEvent(String eventId) async {}
}

VenueEvent _event(
  String id,
  DateTime start, {
  String? notes,
  EventStatus status = EventStatus.planned,
}) =>
    VenueEvent(
      id: id,
      venueId: 'venue-1',
      name: id,
      startTime: start,
      endTime: start.add(const Duration(hours: 3)),
      status: status,
      notes: notes,
    );

void main() {
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Alder & Ash',
    timezone: 'America/Los_Angeles',
    createdAt: DateTime.utc(2026),
  );

  Future<_FakeEventsRepository> pump(
    WidgetTester tester,
    List<VenueEvent> events,
  ) async {
    final repo = _FakeEventsRepository(events);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          eventsRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: EventListScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('tapping an event shows its notes (launch review D5)',
      (tester) async {
    await pump(tester, [
      _event(
        'Late jazz set with the Lloyd Trio',
        // Tue Oct 20 2026, 11:30 PM in Los Angeles (PDT, UTC-7).
        DateTime.utc(2026, 10, 21, 6, 30),
        notes: 'Band loads in at 9:30 through the patio gate.',
      ),
    ]);
    expect(
      find.text('Band loads in at 9:30 through the patio gate.'),
      findsNothing,
    );

    await tester.tap(find.text('Late jazz set with the Lloyd Trio'));
    await tester.pumpAndSettle();

    expect(
      find.text('Band loads in at 9:30 through the patio gate.'),
      findsOneWidget,
    );
    expect(
      find.text('Oct 20, 2026 11:30 PM → Oct 21, 2026 2:30 AM'),
      findsOneWidget,
    );
  });

  testWidgets('add event keeps what was typed until it saves', (tester) async {
    final repo = await pump(tester, []);
    await tester.tap(find.text('Add event'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Notes for the team (optional)'),
      'Needs two outlets by the stage.',
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a name for the event.'), findsOneWidget);
    expect(find.text('Needs two outlets by the stage.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Event name'),
      'Late jazz set',
    );
    repo.failNextCreate = Exception('offline');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not add the event'), findsOneWidget);
    expect(find.text('Late jazz set'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(
      repo.created.single,
      (name: 'Late jazz set', notes: 'Needs two outlets by the stage.'),
    );
    expect(find.text('Notes for the team (optional)'), findsNothing);
  });

  test('upcomingEvents keeps the next week, soonest first, not cancelled', () {
    final now = DateTime.utc(2026, 10, 20, 12);
    final events = [
      _event('next-month', DateTime.utc(2026, 11, 20)),
      _event('tomorrow', DateTime.utc(2026, 10, 21, 2)),
      _event('running', DateTime.utc(2026, 10, 20, 10)),
      _event('ended', DateTime.utc(2026, 10, 19)),
      _event(
        'cancelled',
        DateTime.utc(2026, 10, 22),
        status: EventStatus.cancelled,
      ),
    ];
    expect(
      upcomingEvents(events, now).map((e) => e.id),
      ['running', 'tomorrow'],
    );
  });
}
