import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/time_clock/application/time_clock_providers.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/time_clock_repository.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/time_entry.dart';
import 'package:venuewrangler_mobile/features/time_clock/presentation/time_clock_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeTimeClockRepository implements TimeClockRepository {
  _FakeTimeClockRepository({
    this.activeEntry,
    List<TimeEntry>? entries,
  }) : entries = entries ?? [];

  TimeEntry? activeEntry;
  List<TimeEntry> entries;

  bool clockInCalled = false;
  bool clockOutCalled = false;
  bool startBreakCalled = false;
  bool endBreakCalled = false;

  @override
  Future<TimeEntry?> getActiveEntry({required String venueId}) async => activeEntry;

  @override
  Future<List<TimeEntry>> getMyEntries({required String venueId, int limit = 20}) async => entries;

  @override
  Future<List<TimeEntry>> getVenueEntries({required String venueId, int limit = 50}) async =>
      activeEntry != null ? [activeEntry!, ...entries] : entries;

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
        return TimeBreak(type: b.type, startAt: b.startAt, endAt: DateTime.now());
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

void main() {
  testWidgets('renders CLOCKED OUT state and clocks in', (tester) async {
    final fakeRepo = _FakeTimeClockRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
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

  testWidgets('switches to Clock Board tab and renders active staff', (tester) async {
    final activeStaffEntry = TimeEntry(
      id: 'e1',
      organizationId: 'o1',
      venueId: 'v1',
      userId: 'user-abcdef12',
      clockInAt: DateTime.now().subtract(const Duration(minutes: 45)),
      clockInLat: 29.7604,
      clockInLng: -95.3698,
      clockInAccuracyM: 10.0,
      isOpen: true,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final fakeRepo = _FakeTimeClockRepository(activeEntry: activeStaffEntry);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          timeClockRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: TimeClockScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clock Board'));
    await tester.pumpAndSettle();

    expect(find.text('Active Staff on Duty'), findsOneWidget);
    expect(find.textContaining('user-abc'), findsOneWidget);
  });
}
