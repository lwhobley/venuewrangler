import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/schedules/application/schedules_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/data/schedules_repository.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/schedule_timeline.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/schedules/presentation/schedule_timeline_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venue_clock.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

Shift _shift(String id, String? staff, DateTime start, DateTime end) => Shift(
      id: id,
      venueId: 'venue-1',
      staffId: staff,
      roleLabel: 'Server',
      startTime: start,
      endTime: end,
      status: ShiftStatus.scheduled,
    );

class _FakeRepo implements SchedulesRepository {
  _FakeRepo(this.shifts);

  List<Shift> shifts;
  final calls = <Map<String, Object?>>[];

  @override
  Future<List<Shift>> fetchShiftsForVenue(String venueId) async => shifts;

  @override
  Future<void> updateShift({
    required String shiftId,
    String? staffId,
    bool clearStaff = false,
    String? roleLabel,
    String? section,
    DateTime? startTime,
    DateTime? endTime,
    ShiftStatus? status,
  }) async {
    calls.add({
      'id': shiftId,
      'staffId': staffId,
      'clearStaff': clearStaff,
      'start': startTime,
      'end': endTime,
    });
    shifts = [
      for (final s in shifts)
        if (s.id == shiftId)
          s.copyWith(
            staffId: staffId,
            clearStaff: clearStaff,
            startTime: startTime,
            endTime: endTime,
          )
        else
          s,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  group('timeline logic', () {
    final base = DateTime(2026, 10, 5, 18);

    test('moving snaps to 15 minutes and keeps the length', () {
      final r = movedBy(base, base.add(const Duration(hours: 4)), 30, 56);
      // 30px at 56px/h ≈ 32 min → snaps to 30.
      expect(r.start, DateTime(2026, 10, 5, 18, 30));
      expect(r.end, DateTime(2026, 10, 5, 22, 30));
    });

    test('resizing never goes below the minimum shift length', () {
      final end = base.add(const Duration(hours: 2));
      final r = resizedEndBy(base, end, -500, 56);
      expect(r.end.difference(r.start), kMinShift);
      final s = resizedStartBy(base, end, 500, 56);
      expect(s.end.difference(s.start), kMinShift);
    });

    test('same-person overlaps are conflicts; different people are not', () {
      final a = _shift('a', 'u1', base, base.add(const Duration(hours: 4)));
      final b = _shift(
        'b',
        'u1',
        base.add(const Duration(hours: 3)),
        base.add(const Duration(hours: 6)),
      );
      final c = _shift('c', 'u2', base, base.add(const Duration(hours: 4)));
      final open = _shift('d', null, base, base.add(const Duration(hours: 4)));
      expect(conflictingShiftIds([a, b, c, open]), {'a', 'b'});
    });

    test('scheduled hours clip to the requested range', () {
      final s = _shift('a', 'u1', base, base.add(const Duration(hours: 6)));
      final to = base.add(const Duration(hours: 2));
      expect(
        scheduledHours(
          [s],
          'u1',
          base.subtract(const Duration(hours: 1)),
          to,
        ),
        2,
      );
    });

    test('overlapping shifts in a row get separate lanes', () {
      final a = _shift('a', 'u1', base, base.add(const Duration(hours: 4)));
      final b = _shift(
        'b',
        'u1',
        base.add(const Duration(hours: 1)),
        base.add(const Duration(hours: 3)),
      );
      final lanes = assignLanes([a, b]);
      expect(lanes['a']!.lane, isNot(lanes['b']!.lane));
      expect(lanes['a']!.lanes, 2);
    });

    test('snapping a venue wall time keeps its fields and its UTC flag', () {
      // Wall times are UTC-flagged with the venue's clock in their fields; snapping must not
      // reinterpret them in the device timezone.
      final wall = DateTime.utc(2026, 10, 5, 23, 7);
      final r = movedBy(wall, wall.add(const Duration(hours: 4)), 0, 56);
      expect(r.start, DateTime.utc(2026, 10, 5, 23));
      expect(r.start.isUtc, isTrue);
      expect(clockLabel(wall), '11:07p');
    });

    test('shifts parsed from the database are UTC instants', () {
      final s = Shift.fromJson({
        'id': 'a',
        'venue_id': 'v',
        'start_time': '2026-10-05T23:00:00+00:00',
        'end_time': '2026-10-06T03:00:00+00:00',
        'status': 'scheduled',
      });
      expect(s.startTime.isUtc, isTrue);
      expect(s.startTime, DateTime.utc(2026, 10, 5, 23));
    });

    test('before 6am still belongs to the previous business day', () {
      expect(
        businessDateFor(DateTime(2026, 10, 6, 2)),
        DateTime(2026, 10, 5),
      );
      expect(weekStart(DateTime(2026, 10, 7)), DateTime(2026, 10, 5));
    });
  });

  testWidgets('dragging a shift to another row retimes and reassigns it',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const clock = VenueClock('UTC');
    final dayStart = businessDayStart(businessDateFor(clock.now));
    final start = dayStart.add(const Duration(hours: 12));
    final repo = _FakeRepo([
      _shift('s1', 'alice', start, start.add(const Duration(hours: 4))),
    ]);
    final venue = Venue(
      id: 'venue-1',
      organizationId: 'org',
      name: 'Venue',
      createdAt: DateTime(2026),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          currentUserIdProvider.overrideWithValue('boss'),
          schedulesRepositoryProvider.overrideWithValue(repo),
          canManageActiveVenueProvider.overrideWith((ref) async => true),
          scheduleRosterForVenueProvider.overrideWith(
            (ref, venueId) async => const [
              RosterMember(
                userId: 'alice',
                role: 'staff',
                displayName: 'Alice',
              ),
              RosterMember(userId: 'bob', role: 'staff', displayName: 'Bob'),
              RosterMember(
                userId: 'boss',
                role: 'venue_manager',
                displayName: 'Zed',
              ),
            ],
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const ScheduleTimelineScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Open shifts'), findsOneWidget);
    final block = find.textContaining('Server');
    expect(block, findsOneWidget);

    // Press and hold to pick the shift up, then drag.
    final gesture = await tester.startGesture(tester.getCenter(block));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(120, 80));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(repo.calls, hasLength(1));
    final call = repo.calls.single;
    expect(call['staffId'], 'bob');
    expect((call['start']! as DateTime).isAfter(start), isTrue);
    expect(
      (call['end']! as DateTime).difference(call['start']! as DateTime),
      const Duration(hours: 4),
    );
  });

  group('venue time zone', () {
    Future<_FakeRepo> pumpBoard(
      WidgetTester tester,
      String timezone,
      List<Shift> shifts,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo(shifts);
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
            currentUserIdProvider.overrideWithValue('boss'),
            schedulesRepositoryProvider.overrideWithValue(repo),
            canManageActiveVenueProvider.overrideWith((ref) async => true),
            scheduleRosterForVenueProvider.overrideWith(
              (ref, venueId) async => const [
                RosterMember(
                  userId: 'alice',
                  role: 'staff',
                  displayName: 'Alice',
                ),
                RosterMember(userId: 'bob', role: 'staff', displayName: 'Bob'),
              ],
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const ScheduleTimelineScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    Future<void> dragShift(WidgetTester tester) async {
      final block = find.textContaining('Server');
      final gesture = await tester.startGesture(tester.getCenter(block));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets(
        'shows shifts on the venue clock and saves moves as real instants',
        (tester) async {
      const clock =
          VenueClock('Africa/Johannesburg'); // UTC+2, never the device zone
      final wallStart = businessDayStart(businessDateFor(clock.now))
          .add(const Duration(hours: 12));
      final start = clock.instant(wallStart); // 16:00Z
      final repo = await pumpBoard(tester, 'Africa/Johannesburg', [
        _shift('s1', 'alice', start, start.add(const Duration(hours: 4))),
      ]);

      // The business day starts at 6am, so +12h is 18:00-22:00 *venue* time, whatever the
      // device timezone is.
      expect(find.textContaining('6p–10p'), findsWidgets);

      await dragShift(tester);

      final saved = repo.calls.single['start']! as DateTime;
      expect(saved.isUtc, isTrue);
      expect(saved.isAfter(start), isTrue);
      // Still a whole venue-clock quarter hour: the move was made in venue time.
      expect(clock.wall(saved).minute % 15, 0);
      expect(
        (repo.calls.single['end']! as DateTime).difference(saved),
        const Duration(hours: 4),
      );
    });

    testWidgets('an unsupported zone warns and refuses to save',
        (tester) async {
      const clock = VenueClock('UTC');
      final start = businessDayStart(businessDateFor(clock.now))
          .add(const Duration(hours: 12));
      final repo = await pumpBoard(tester, 'Mars/Olympus_Mons', [
        _shift('s1', 'alice', start, start.add(const Duration(hours: 4))),
      ]);

      expect(
        find.byKey(const ValueKey('unsupported-timezone-banner')),
        findsOneWidget,
      );

      await dragShift(tester);

      expect(repo.calls, isEmpty);
      expect(find.textContaining("isn't supported"), findsWidgets);
    });
  });
}
