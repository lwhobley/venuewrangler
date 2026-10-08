import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/guest.dart';
import '../domain/reservation.dart';

abstract class GuestsReservationsRepository {
  Future<List<Guest>> getGuests({required String venueId, int limit = 50});
  Future<Guest> createGuest({
    required String venueId,
    required String fullName,
    String? phone,
    String? email,
    String? notes,
    String? dietaryNotes,
    List<String> tags = const [],
  });

  Future<List<Reservation>> getReservations({
    required String venueId,
    DateTime? from,
    DateTime? to,
    int limit = 50,
  });

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
  });

  Future<void> updateReservationStatus({
    required String reservationId,
    required String status,
  });

  /// Assigns the reservation to a team member, or clears it when [userId] is null.
  Future<void> assignReservation({
    required String reservationId,
    String? userId,
  });
}

class SupabaseGuestsReservationsRepository
    implements GuestsReservationsRepository {
  SupabaseGuestsReservationsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Guest>> getGuests({
    required String venueId,
    int limit = 50,
  }) async {
    final response = await _client
        .from('guests')
        .select()
        .eq('venue_id', venueId)
        .order('full_name', ascending: true)
        .limit(limit);

    return (response as List<dynamic>)
        .map((row) => Guest.fromJson(row as Map<String, dynamic>))
        .toList();
  }

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
    // Note: organization_id is derived by DB trigger from venue_id, but supabase client requires non-null column
    // or placeholder that trigger overrides. Passing dummy uuid or querying venue org.
    final venueRow = await _client
        .from('venues')
        .select('organization_id')
        .eq('id', venueId)
        .single();
    final orgId = venueRow['organization_id'] as String;

    final response = await _client
        .from('guests')
        .insert({
          'venue_id': venueId,
          'organization_id': orgId,
          'full_name': fullName,
          if (phone != null) 'phone': phone,
          if (email != null) 'email': email,
          if (notes != null) 'notes': notes,
          if (dietaryNotes != null) 'dietary_notes': dietaryNotes,
          'tags': tags,
        })
        .select()
        .single();

    return Guest.fromJson(response);
  }

  @override
  Future<List<Reservation>> getReservations({
    required String venueId,
    DateTime? from,
    DateTime? to,
    int limit = 50,
  }) async {
    final now = DateTime.now().toUtc();
    final windowFrom = from ?? now.subtract(const Duration(days: 30));
    final windowTo = to ?? now.add(const Duration(days: 365));
    final useDefaultWindow = from == null && to == null;
    const pageSize = 500;
    final reservations = <Reservation>[];
    for (var offset = 0;; offset += pageSize) {
      final query = _client
          .from('reservations')
          .select()
          .eq('venue_id', venueId)
          .gte('reservation_time', windowFrom.toIso8601String())
          .lte('reservation_time', windowTo.toIso8601String());
      final rows = await query
          .order('reservation_time')
          .order('id')
          .range(offset, offset + (useDefaultWindow ? pageSize : limit) - 1);
      reservations.addAll(rows.map(Reservation.fromJson));
      if (!useDefaultWindow || rows.length < pageSize) break;
    }
    return reservations;
  }

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
    final venueRow = await _client
        .from('venues')
        .select('organization_id')
        .eq('id', venueId)
        .single();
    final orgId = venueRow['organization_id'] as String;

    final response = await _client
        .from('reservations')
        .insert({
          'venue_id': venueId,
          'organization_id': orgId,
          if (guestId != null) 'guest_id': guestId,
          'guest_name': guestName,
          if (guestPhone != null) 'guest_phone': guestPhone,
          if (guestEmail != null) 'guest_email': guestEmail,
          'party_size': partySize,
          'reservation_time': reservationTime.toUtc().toIso8601String(),
          'duration_minutes': durationMinutes,
          'source': source,
          if (specialRequests != null) 'special_requests': specialRequests,
          if (depositDueCents != null) 'deposit_due_cents': depositDueCents,
          if (depositDueCents != null && depositDueCents > 0)
            'deposit_status': 'required',
        })
        .select()
        .single();

    return Reservation.fromJson(response);
  }

  @override
  Future<void> updateReservationStatus({
    required String reservationId,
    required String status,
  }) async {
    final updates = <String, dynamic>{'status': status};
    if (status == 'seated') {
      updates['seated_at'] = DateTime.now().toUtc().toIso8601String();
    } else if (status == 'completed') {
      updates['completed_at'] = DateTime.now().toUtc().toIso8601String();
    } else if (status == 'cancelled') {
      updates['cancelled_at'] = DateTime.now().toUtc().toIso8601String();
    }

    await _client.from('reservations').update(updates).eq('id', reservationId);
  }

  @override
  Future<void> assignReservation({
    required String reservationId,
    String? userId,
  }) async {
    await _client
        .from('reservations')
        .update({'assigned_to': userId}).eq('id', reservationId);
  }
}
