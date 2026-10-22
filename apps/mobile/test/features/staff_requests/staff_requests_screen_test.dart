import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/application/schedules_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/staff_requests/application/staff_requests_providers.dart';
import 'package:venuewrangler_mobile/features/staff_requests/data/staff_requests_repository.dart';
import 'package:venuewrangler_mobile/features/staff_requests/domain/staff_request.dart';
import 'package:venuewrangler_mobile/features/staff_requests/presentation/staff_requests_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

class _FakeStaffRequestsRepository implements StaffRequestsRepository {
  _FakeStaffRequestsRepository(this.requests);

  List<StaffRequest> requests;
  String? lastCreatedTitle;
  StaffRequestKind? lastCreatedKind;
  String? lastCancelledId;
  String? lastReviewedId;
  StaffRequestStatus? lastReviewedStatus;
  String? lastResponseNotes;
  bool? lastAllowOverlap;
  String? lastCreatedShiftId;
  String? lastCreatedStart;

  @override
  Future<List<StaffRequest>> fetchRequestsForVenue(String venueId) async =>
      requests;

  @override
  Future<void> createRequest({
    required String venueId,
    required StaffRequestKind kind,
    required String title,
    String details = '',
    String? requestedForDate,
    String? requestedRangeStart,
    String? requestedRangeEnd,
    String? requestedShiftId,
  }) async {
    lastCreatedTitle = title;
    lastCreatedKind = kind;
    lastCreatedShiftId = requestedShiftId;
    lastCreatedStart = requestedRangeStart;
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    lastCancelledId = requestId;
  }

  @override
  Future<void> reviewRequest({
    required String requestId,
    required StaffRequestStatus status,
    String? responseNotes,
    bool allowOverlap = false,
  }) async {
    lastAllowOverlap = allowOverlap;
    lastReviewedId = requestId;
    lastReviewedStatus = status;
    lastResponseNotes = responseNotes;
  }
}

final _testVenue = Venue(
  id: 'v1',
  organizationId: 'o1',
  name: 'Test Venue',
  createdAt: DateTime(2026),
);

StaffRequest _makeRequest({
  required String id,
  required String title,
  StaffRequestKind kind = StaffRequestKind.timeOff,
  StaffRequestStatus status = StaffRequestStatus.pending,
  String userId = 'u1',
  String? shiftId,
}) =>
    StaffRequest(
      id: id,
      venueId: 'v1',
      organizationId: 'o1',
      userId: userId,
      kind: kind,
      status: status,
      title: title,
      requestedShiftId: shiftId,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

final _soon = DateTime.now().toUtc().add(const Duration(days: 2));
final _openBusser = Shift(
  id: 'open-1',
  venueId: 'v1',
  roleLabel: 'Busser',
  startTime: _soon,
  endTime: _soon.add(const Duration(hours: 4)),
  status: ShiftStatus.scheduled,
);
final _u2Bar = Shift(
  id: 'bar-1',
  venueId: 'v1',
  staffId: 'u2',
  roleLabel: 'Bartender',
  startTime: _soon.subtract(const Duration(hours: 1)),
  endTime: _soon.add(const Duration(hours: 6)),
  status: ShiftStatus.scheduled,
);

List<Override> _scheduleOverrides() => [
      shiftsForVenueProvider
          .overrideWith((ref, venueId) async => [_openBusser, _u2Bar]),
      scheduleRosterForVenueProvider.overrideWith(
        (ref, venueId) async => const [
          RosterMember(userId: 'u1', role: 'staff', displayName: 'Ingrid'),
          RosterMember(userId: 'u2', role: 'staff', displayName: 'Jada Echols'),
        ],
      ),
    ];

void main() {
  testWidgets('shows empty state when no staff requests', (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('u1'),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
          ..._scheduleOverrides(),
        ],
        child: const MaterialApp(home: StaffRequestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No staff requests yet.'), findsOneWidget);
  });

  testWidgets('lists requests and displays kind and status', (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([
      _makeRequest(
        id: 'r1',
        title: 'Doctor appointment',
        kind: StaffRequestKind.timeOff,
        status: StaffRequestStatus.pending,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('u1'),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
          ..._scheduleOverrides(),
        ],
        child: const MaterialApp(home: StaffRequestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Doctor appointment'), findsOneWidget);
    expect(find.text('Time Off • Pending'), findsOneWidget);
  });

  testWidgets('creating a staff request from dialog calls repository',
      (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('u1'),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
          ..._scheduleOverrides(),
        ],
        child: const MaterialApp(home: StaffRequestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final fab = find.byType(FloatingActionButton);
    expect(fab, findsOneWidget);
    await tester.tap(fab);
    await tester.pumpAndSettle();

    expect(find.text('New Staff Request'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Title'),
      'Vacation request',
    );
    // Time off needs a day; the dialog says so and keeps what was typed.
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();
    expect(find.text('Choose the first day you need off.'), findsOneWidget);
    expect(find.text('Vacation request'), findsOneWidget);
    expect(fakeRepo.lastCreatedTitle, isNull);

    await tester.tap(find.text('First day'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastCreatedTitle, 'Vacation request');
    expect(fakeRepo.lastCreatedKind, StaffRequestKind.timeOff);
    expect(fakeRepo.lastCreatedStart, isNotNull);
  });

  testWidgets('cancelling a pending request calls repository', (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([
      _makeRequest(
        id: 'r1',
        title: 'Shift pickup',
        userId: 'u1',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('u1'),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
          ..._scheduleOverrides(),
        ],
        child: const MaterialApp(home: StaffRequestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final cancelBtn = find.widgetWithText(TextButton, 'Cancel');
    expect(cancelBtn, findsOneWidget);

    await tester.tap(cancelBtn);
    await tester.pumpAndSettle();

    expect(fakeRepo.lastCancelledId, 'r1');
  });

  testWidgets('approving a pending request calls repository', (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([
      _makeRequest(
        id: 'r1',
        title: 'Shift pickup',
        userId: 'u2',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('u1'),
          canManageActiveVenueProvider.overrideWith((ref) async => true),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
          ..._scheduleOverrides(),
        ],
        child: const MaterialApp(home: StaffRequestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final popupMenu = find.byType(PopupMenuButton<String>);
    expect(popupMenu, findsOneWidget);

    await tester.tap(popupMenu);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();

    expect(find.text('Approved Request'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Approved'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastReviewedId, 'r1');
    expect(fakeRepo.lastReviewedStatus, StaffRequestStatus.approved);
  });

  testWidgets('staff can ask to pick up an open shift, titled for them',
      (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('u1'),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
          ..._scheduleOverrides(),
        ],
        child: const MaterialApp(home: StaffRequestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Time Off').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick Up Shift').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open shift'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Busser').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastCreatedKind, StaffRequestKind.addShift);
    expect(fakeRepo.lastCreatedShiftId, 'open-1');
    expect(fakeRepo.lastCreatedTitle, startsWith('Pick up '));
    expect(fakeRepo.lastCreatedTitle, endsWith(' Busser'));
  });

  testWidgets(
      'managers see who asked and which shift, and are warned before '
      'approving a double-booking pick-up', (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([
      _makeRequest(
        id: 'r1',
        title: 'Pick up busser',
        kind: StaffRequestKind.addShift,
        userId: 'u2',
        shiftId: 'open-1',
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('boss'),
          canManageActiveVenueProvider.overrideWith((ref) async => true),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
          ..._scheduleOverrides(),
        ],
        child: const MaterialApp(home: StaffRequestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('From: Jada Echols'), findsOneWidget);
    expect(find.textContaining('Shift: '), findsOneWidget);
    expect(find.textContaining('Busser'), findsWidgets);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Jada Echols already works Bartender'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Approve anyway'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastReviewedStatus, StaffRequestStatus.approved);
    expect(fakeRepo.lastAllowOverlap, isTrue);
  });
}
