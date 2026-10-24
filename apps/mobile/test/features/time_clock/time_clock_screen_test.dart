import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/core/location/location_service.dart';
import 'package:venuewrangler_mobile/features/time_clock/application/time_clock_providers.dart';
import 'package:venuewrangler_mobile/features/time_clock/application/timesheet_providers.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/time_clock_repository.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/time_entry.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/timesheet.dart';
import 'package:venuewrangler_mobile/features/time_clock/presentation/time_clock_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeTimeClockRepository implements TimeClockRepository {
  _FakeTimeClockRepository({
    this.activeEntry,
    List<TimeEntry>? entries,
  }) : entries = entries ?? [];

  TimeEntry? activeEntry;

  /// An open entry at a different venue (reported by getOpenEntryElsewhere only).
  TimeEntry? openElsewhere;
  List<TimeEntry> entries;

  bool clockInCalled = false;
  bool clockOutCalled = false;
  bool startBreakCalled = false;
  bool endBreakCalled = false;

  @override
  Future<TimeEntry?> getActiveEntry({required String venueId}) async =>
      activeEntry;

  @override
  Future<TimeEntry?> getOpenEntryElsewhere({required String venueId}) async =>
      openElsewhere;

  @override
  Future<List<TimeEntry>> getMyEntries({
    required String venueId,
    int limit = 20,
  }) async =>
      entries;

  @override
  Future<TimeEntry> clockIn({
    required String venueId,
    String? shiftId,
    required double lat,
    required double lng,
    required double accuracyM,
    bool mocked = false,
  }) async {
    clockInCalled = true;
    final newEntry = TimeEntry(
      id: 'e-new',
      organizationId: 'o1',
      venueId: venueId,
      userId: 'user-12345678',
      clockInAt: DateTime.now(),
      clockInLat: lat,
      clockInLng: lng,
      clockInAccuracyM: accuracyM,
      isOpen: true,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    activeEntry = newEntry;
    return newEntry;
  }

  @override
  Future<TimeEntry> clockOut({
    required String entryId,
    required double lat,
    required double lng,
    required double accuracyM,
    bool mocked = false,
  }) async {
    clockOutCalled = true;
    final closed = activeEntry!.copyWith(
      isOpen: false,
      clockOutAt: DateTime.now(),
      clockOutLat: lat,
      clockOutLng: lng,
      clockOutAccuracyM: accuracyM,
    );
    entries.insert(0, closed);
    activeEntry = null;
    return closed;
  }

  @override
  Future<TimeEntry> startBreak({
    required TimeEntry entry,
    required String type,
  }) async {
    startBreakCalled = true;
    final updatedBreaks = List<TimeBreak>.from(entry.breaks)
      ..add(TimeBreak(type: type, startAt: DateTime.now()));
    final updated = entry.copyWith(breaks: updatedBreaks);
    activeEntry = updated;
    return updated;
  }

  @override
  Future<TimeEntry> endBreak({required TimeEntry entry}) async {
    endBreakCalled = true;
    final updatedBreaks = entry.breaks.map((b) {
      if (b.isOpen) {
        return TimeBreak(
          type: b.type,
          startAt: b.startAt,
          endAt: DateTime.now(),
        );
      }
      return b;
    }).toList();
    final updated = entry.copyWith(breaks: updatedBreaks);
    activeEntry = updated;
    return updated;
  }
}

extension on TimeEntry {
  TimeEntry copyWith({
    String? id,
    String? organizationId,
    String? venueId,
    String? userId,
    DateTime? clockInAt,
    double? clockInLat,
    double? clockInLng,
    double? clockInAccuracyM,
    DateTime? clockOutAt,
    double? clockOutLat,
    double? clockOutLng,
    double? clockOutAccuracyM,
    bool? isOpen,
    List<TimeBreak>? breaks,
  }) =>
      TimeEntry(
        id: id ?? this.id,
        organizationId: organizationId ?? this.organizationId,
        venueId: venueId ?? this.venueId,
        userId: userId ?? this.userId,
        clockInAt: clockInAt ?? this.clockInAt,
        clockInLat: clockInLat ?? this.clockInLat,
        clockInLng: clockInLng ?? this.clockInLng,
        clockInAccuracyM: clockInAccuracyM ?? this.clockInAccuracyM,
        clockOutAt: clockOutAt ?? this.clockOutAt,
        clockOutLat: clockOutLat ?? this.clockOutLat,
        clockOutLng: clockOutLng ?? this.clockOutLng,
        clockOutAccuracyM: clockOutAccuracyM ?? this.clockOutAccuracyM,
        isOpen: isOpen ?? this.isOpen,
        breaks: breaks ?? this.breaks,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

final _testVenue = Venue(
  id: 'v1',
  organizationId: 'o1',
  name: 'Main Stage Venue',
  createdAt: DateTime(2026),
);

class _FakeLocationService implements LocationService {
  @override
  Future<LocationFix> currentFix() async =>
      const LocationFix(lat: 40.0, lng: -74.0, accuracyM: 8, mocked: false);
}

class _DeniedLocationService implements LocationService {
  @override
  Future<LocationFix> currentFix() async => throw const PermissionDeniedError(
        'Location permission is required to clock in or out.',
      );
}

void main() {
  testWidgets('renders CLOCKED OUT state and clocks in', (tester) async {
    final fakeRepo = _FakeTimeClockRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CLOCKED OUT'), findsOneWidget);
    expect(find.text('Clock In'), findsOneWidget);

    await tester.tap(find.text('Clock In'));
    await tester.pumpAndSettle();

    expect(fakeRepo.clockInCalled, true);
    expect(find.text('CLOCKED IN'), findsOneWidget);
    expect(find.text('Take Break'), findsOneWidget);
    expect(find.text('Clock Out'), findsOneWidget);
  });

  testWidgets('on web the punch buttons are replaced by a mobile-app notice',
      (tester) async {
    final fakeRepo = _FakeTimeClockRepository(
      entries: [
        TimeEntry(
          id: 'e-old',
          organizationId: 'o1',
          venueId: 'v1',
          userId: 'user-12345678',
          clockInAt: DateTime(2026, 1, 5, 9),
          clockOutAt: DateTime(2026, 1, 5, 17),
          clockInLat: 40.0,
          clockInLng: -74.0,
          clockInAccuracyM: 8,
          isOpen: false,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
          timeClockPunchSupportedProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Clock in/out requires the mobile app'),
      findsOneWidget,
    );
    expect(find.text('Clock In'), findsNothing);
    expect(find.text('Clock Out'), findsNothing);
    // History is still readable.
    expect(find.text('Recent Punches'), findsOneWidget);
    expect(find.textContaining('1/5'), findsOneWidget);
    expect(fakeRepo.clockInCalled, isFalse);
  });

  testWidgets('a closed punch whose GPS was purged still renders in history',
      (tester) async {
    final fakeRepo = _FakeTimeClockRepository(
      entries: [
        TimeEntry(
          id: 'e-purged',
          organizationId: 'o1',
          venueId: 'v1',
          userId: 'user-12345678',
          clockInAt: DateTime(2025, 1, 6, 9),
          clockOutAt: DateTime(2025, 1, 6, 17),
          isOpen: false,
          createdAt: DateTime(2025),
          updatedAt: DateTime(2025),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1/6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clock in is blocked, not faked, when location is denied',
      (tester) async {
    final fakeRepo = _FakeTimeClockRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
          locationServiceProvider.overrideWithValue(_DeniedLocationService()),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clock In'));
    await tester.pumpAndSettle();

    expect(fakeRepo.clockInCalled, false);
    expect(
      find.text('Location permission is required to clock in or out.'),
      findsOneWidget,
    );
    expect(find.text('CLOCKED OUT'), findsOneWidget);
  });

  testWidgets('an open entry at another venue is not shown as clocked in here',
      (tester) async {
    final fakeRepo = _FakeTimeClockRepository()
      ..openElsewhere = TimeEntry(
        id: 'e-other',
        organizationId: 'o1',
        venueId: 'v2',
        userId: 'user-12345678',
        clockInAt: DateTime.now().subtract(const Duration(hours: 1)),
        clockInLat: 40.0,
        clockInLng: -74.0,
        clockInAccuracyM: 8,
        isOpen: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CLOCKED OUT'), findsOneWidget);
    expect(find.textContaining('clocked in at another venue'), findsOneWidget);
    expect(find.text('Clock Out'), findsNothing);
    final clockIn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Clock In'),
    );
    expect(clockIn.onPressed, isNull);
  });

  testWidgets('handles break workflow (start and end break)', (tester) async {
    final clockedInEntry = TimeEntry(
      id: 'e1',
      organizationId: 'o1',
      venueId: 'v1',
      userId: 'user-12345678',
      clockInAt: DateTime.now().subtract(const Duration(hours: 2)),
      clockInLat: 29.7604,
      clockInLng: -95.3698,
      clockInAccuracyM: 10.0,
      isOpen: true,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final fakeRepo = _FakeTimeClockRepository(activeEntry: clockedInEntry);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CLOCKED IN'), findsOneWidget);

    // Tap Take Break -> dialog opens
    await tester.tap(find.text('Take Break'));
    await tester.pumpAndSettle();

    expect(find.text('Paid Break (15 min)'), findsOneWidget);
    await tester.tap(find.text('Paid Break (15 min)'));
    await tester.pumpAndSettle();

    expect(fakeRepo.startBreakCalled, true);
    expect(find.text('ON BREAK'), findsOneWidget);
    expect(find.text('End Break'), findsOneWidget);

    // Tap End Break
    await tester.tap(find.text('End Break'));
    await tester.pumpAndSettle();

    expect(fakeRepo.endBreakCalled, true);
    expect(find.text('CLOCKED IN'), findsOneWidget);
  });

  testWidgets('clocks out from active punch', (tester) async {
    final clockedInEntry = TimeEntry(
      id: 'e1',
      organizationId: 'o1',
      venueId: 'v1',
      userId: 'user-12345678',
      clockInAt: DateTime.now().subtract(const Duration(hours: 4)),
      clockInLat: 29.7604,
      clockInLng: -95.3698,
      clockInAccuracyM: 10.0,
      isOpen: true,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final fakeRepo = _FakeTimeClockRepository(activeEntry: clockedInEntry);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clock Out'), findsOneWidget);

    await tester.tap(find.text('Clock Out'));
    await tester.pumpAndSettle();

    expect(fakeRepo.clockOutCalled, true);
    expect(find.text('CLOCKED OUT'), findsOneWidget);
  });

  testWidgets('the Clock Board lists people by name, in venue time',
      (tester) async {
    final clockIn = DateTime.utc(2026, 10, 22, 6, 25); // 1:25 AM in Chicago
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith(
            (ref) => Venue(
              id: 'v1',
              organizationId: 'o1',
              name: 'Fulton & Pine',
              timezone: 'America/Chicago',
              latitude: 41.88,
              longitude: -87.65,
              createdAt: DateTime(2026),
            ),
          ),
          timeClockRepositoryProvider
              .overrideWithValue(_FakeTimeClockRepository()),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
          myVenueRoleProvider.overrideWith((ref) async => 'venue_manager'),
          currentUserIdProvider.overrideWithValue('manager-1'),
          venueClockBoardProvider.overrideWith(
            (ref, venueId) async => [
              ClockBoardRow(
                timeEntryId: 'e1',
                userId: '942448ed-0000',
                displayName: 'Colin Park',
                clockInAt: clockIn,
              ),
            ],
          ),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clock Board'));
    await tester.pumpAndSettle();

    expect(find.text('Active Staff on Duty'), findsOneWidget);
    expect(find.text('Colin Park'), findsOneWidget);
    expect(find.textContaining('Staff ID'), findsNothing);
    expect(find.textContaining('Clocked in at 01:25'), findsOneWidget);
    // Managers can close a teammate's missed clock-out from the board.
    expect(find.byTooltip('Close missed clock-out'), findsOneWidget);
    expect(find.byTooltip('Hours & payroll export'), findsOneWidget);
  });

  testWidgets('staff get no Clock Board tab', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider
              .overrideWithValue(_FakeTimeClockRepository()),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
          myVenueRoleProvider.overrideWith((ref) async => 'staff'),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clock Board'), findsNothing);
    expect(find.text('Clock In'), findsOneWidget);
    expect(find.byTooltip('Hours & payroll export'), findsNothing);
    // Staff are not shown the manager prompt either.
    expect(find.text("Set your venue's location"), findsNothing);
  });

  testWidgets('managers are told to set a missing venue location',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider
              .overrideWithValue(_FakeTimeClockRepository()),
          locationServiceProvider.overrideWithValue(_FakeLocationService()),
          myVenueRoleProvider.overrideWith((ref) async => 'venue_manager'),
          currentUserIdProvider.overrideWithValue('manager-1'),
          venueClockBoardProvider.overrideWith((ref, venueId) async => []),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Set your venue's location"), findsOneWidget);
    expect(find.text('Set location'), findsOneWidget);
  });
}
