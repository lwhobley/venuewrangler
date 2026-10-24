import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/application/schedules_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/data/schedules_repository.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/schedules/presentation/schedule_list_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venue_clock.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

class _Repo implements SchedulesRepository {
  _Repo(this.shifts);

  final List<Shift> shifts;
  final created = <({String? staffId, DateTime start, DateTime end})>[];

  @override
  Future<List<Shift>> fetchShiftsForVenue(String venueId) async => shifts;

  @override
  Future<List<ShiftSwap>> fetchSwapsForVenue(String venueId) async => const [];

  @override
  Future<void> createShift({
    required String venueId,
    String? staffId,
    String? roleLabel,
    String? section,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    created.add((staffId: staffId, start: startTime, end: endTime));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _alice = RosterMember(
  userId: 'alice-id',
  role: 'staff',
  displayName: 'Alice Adams',
);

Future<_Repo> _pump(
  WidgetTester tester, {
  String timezone = 'America/Chicago',
  List<Shift> shifts = const [],
  bool manager = true,
}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _Repo(shifts);
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org',
    name: 'Venue',
    timezone: timezone,
    createdAt: DateTime(2026),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeVenueProvider.overrideWith((ref) => venue),
        schedulesRepositoryProvider.overrideWithValue(repo),
        canManageActiveVenueProvider.overrideWith((ref) async => manager),
        currentUserIdProvider.overrideWithValue('boss'),
        scheduleRosterForVenueProvider
            .overrideWith((ref, venueId) async => const [_alice]),
      ],
      child: const MaterialApp(home: ScheduleListScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('Add shift offers a roster picker, not a typed user id',
      (tester) async {
    final repo = await _pump(tester);

    await tester.tap(find.text('Add shift'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Staff user ID'), findsNothing);
    expect(find.text('Assigned to'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    expect(find.text('Open shift (unassigned)'), findsWidgets);
    await tester.tap(find.text('Alice Adams').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final saved = repo.created.single;
    expect(saved.staffId, 'alice-id');
    expect(saved.start.isUtc, isTrue);
    expect(saved.end.difference(saved.start), const Duration(hours: 4));
  });

  testWidgets(
      'the saved start is the venue clock reading, not the device clock',
      (tester) async {
    final repo = await _pump(tester, timezone: 'Africa/Johannesburg');
    const clock = VenueClock('Africa/Johannesburg');
    final before = clock.now;

    await tester.tap(find.text('Add shift'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final start = repo.created.single.start;
    final wall = clock.wall(start);
    // The dialog's default start is "now" on the venue's wall clock.
    expect(wall.difference(before).inMinutes.abs(), lessThanOrEqualTo(2));
    expect(repo.created.single.staffId, isNull); // open shift
  });

  testWidgets('shifts are listed in venue time with the person named',
      (tester) async {
    const clock = VenueClock('Africa/Johannesburg');
    final start = clock.instant(DateTime.utc(2026, 10, 20, 9));
    await _pump(
      tester,
      timezone: 'Africa/Johannesburg',
      shifts: [
        Shift(
          id: 's1',
          venueId: 'venue-1',
          staffId: 'alice-id',
          roleLabel: 'Bartender',
          startTime: start,
          endTime: start.add(const Duration(hours: 4)),
          status: ShiftStatus.scheduled,
        ),
      ],
    );

    expect(find.textContaining('Oct 20, 2026 9:00 AM'), findsOneWidget);
    expect(find.textContaining('Staff: Alice Adams'), findsOneWidget);
  });

  testWidgets('an unsupported zone shows the banner and blocks Add shift',
      (tester) async {
    final repo = await _pump(tester, timezone: 'Mars/Olympus_Mons');

    expect(
      find.byKey(const ValueKey('unsupported-timezone-banner')),
      findsOneWidget,
    );

    await tester.tap(find.text('Add shift'));
    await tester.pumpAndSettle();

    expect(find.text('Assigned to'), findsNothing);
    expect(find.textContaining("isn't supported"), findsWidgets);
    expect(repo.created, isEmpty);
  });

  testWidgets('managers are offered Draft week', (tester) async {
    await _pump(tester);
    expect(find.text('Draft week'), findsOneWidget);
  });

  testWidgets('staff are not offered Draft week', (tester) async {
    await _pump(tester, manager: false);
    expect(find.text('Draft week'), findsNothing);
  });
}
