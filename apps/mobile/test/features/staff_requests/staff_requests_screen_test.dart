import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/staff_requests/application/staff_requests_providers.dart';
import 'package:venuewrangler_mobile/features/staff_requests/data/staff_requests_repository.dart';
import 'package:venuewrangler_mobile/features/staff_requests/domain/staff_request.dart';
import 'package:venuewrangler_mobile/features/staff_requests/presentation/staff_requests_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeStaffRequestsRepository implements StaffRequestsRepository {
  _FakeStaffRequestsRepository(this.requests);

  List<StaffRequest> requests;
  String? lastCreatedTitle;
  StaffRequestKind? lastCreatedKind;
  String? lastCancelledId;
  String? lastReviewedId;
  StaffRequestStatus? lastReviewedStatus;
  String? lastResponseNotes;

  @override
  Future<List<StaffRequest>> fetchRequestsForVenue(String venueId) async => requests;

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
  }) async {
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
}) =>
    StaffRequest(
      id: id,
      venueId: 'v1',
      organizationId: 'o1',
      userId: userId,
      kind: kind,
      status: status,
      title: title,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  testWidgets('shows empty state when no staff requests', (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('u1'),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
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
        ],
        child: const MaterialApp(home: StaffRequestsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Doctor appointment'), findsOneWidget);
    expect(find.text('Time Off • Pending'), findsOneWidget);
  });

  testWidgets('creating a staff request from dialog calls repository', (tester) async {
    final fakeRepo = _FakeStaffRequestsRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => _testVenue),
          currentUserIdProvider.overrideWithValue('u1'),
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
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
    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastCreatedTitle, 'Vacation request');
    expect(fakeRepo.lastCreatedKind, StaffRequestKind.timeOff);
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
          staffRequestsRepositoryProvider.overrideWithValue(fakeRepo),
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
}
