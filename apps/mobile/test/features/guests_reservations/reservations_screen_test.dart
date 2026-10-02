import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/application/guests_reservations_providers.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/data/guests_reservations_repository.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/domain/guest.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/domain/reservation.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/presentation/reservations_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeGuestsReservationsRepository implements GuestsReservationsRepository {
  _FakeGuestsReservationsRepository({List<Reservation>? initialReservations})
      : reservations = initialReservations ?? [];

  List<Reservation> reservations;
  bool updateStatusCalled = false;
  String? updatedReservationId;
  String? updatedStatus;
  bool createReservationCalled = false;

  @override
  Future<List<Guest>> getGuests({required String venueId, int limit = 50}) async => [];

  @override
  Future<Guest> createGuest({
    required String venueId,
    required String fullName,
    String? phone,
    String? email,
    String? notes,
    String? dietaryNotes,
    List<String> tags = const [],
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<Reservation>> getReservations({
    required String venueId,
    DateTime? from,
    DateTime? to,
    int limit = 50,
  }) async => reservations;

  @override
  Future<Reservation> createReservation({
    required String venueId,
    String? guestId,
    required String guestName,
    String? guestPhone,
    String? guestEmail,
    required int partySize,
    required DateTime reservationTime,
    int durationMinutes = 90,
    String source = 'direct',
    String? specialRequests,
    int? depositDueCents,
  }) async {
    createReservationCalled = true;
    final r = Reservation(
      id: 'res-new-1',
      organizationId: 'org-1',
      venueId: venueId,
      guestName: guestName,
      partySize: partySize,
      reservationTime: reservationTime,
      source: source,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    reservations.add(r);
    return r;
  }

  @override
  Future<void> updateReservationStatus({
    required String reservationId,
    required String status,
  }) async {
    updateStatusCalled = true;
    updatedReservationId = reservationId;
    updatedStatus = status;
    final idx = reservations.indexWhere((r) => r.id == reservationId);
    if (idx != -1) {
      final old = reservations[idx];
      reservations[idx] = Reservation(
        id: old.id,
        organizationId: old.organizationId,
        venueId: old.venueId,
        guestId: old.guestId,
        guestName: old.guestName,
        partySize: old.partySize,
        reservationTime: old.reservationTime,
        durationMinutes: old.durationMinutes,
        source: old.source,
        status: status,
        createdAt: old.createdAt,
        updatedAt: DateTime.now(),
      );
    }
  }
}

void main() {
  final testVenue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime.now(),
  );

  testWidgets('renders empty state when no reservations exist', (tester) async {
    final fakeRepo = _FakeGuestsReservationsRepository(initialReservations: []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          guestsReservationsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ReservationsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Reservations'), findsOneWidget);
    expect(find.text('No reservations found'), findsOneWidget);
  });

  testWidgets('renders reservations list and filters by status', (tester) async {
    final fakeRepo = _FakeGuestsReservationsRepository(
      initialReservations: [
        Reservation(
          id: 'res-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          guestName: 'John Doe',
          partySize: 4,
          reservationTime: DateTime.now().add(const Duration(hours: 2)),
          status: 'confirmed',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        Reservation(
          id: 'res-2',
          organizationId: 'org-1',
          venueId: 'venue-1',
          guestName: 'Jane Smith',
          partySize: 2,
          reservationTime: DateTime.now().add(const Duration(hours: 3)),
          status: 'seated',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          guestsReservationsRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: ReservationsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('John Doe'), findsOneWidget);
    expect(find.text('Jane Smith'), findsOneWidget);

    // Filter to 'Seated'
    await tester.tap(find.text('Seated'));
    await tester.pumpAndSettle();

    expect(find.text('John Doe'), findsNothing);
    expect(find.text('Jane Smith'), findsOneWidget);
  });
}
