import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/shift.dart';

/// As with the other Phase 2/3 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002120000_schedules_schema.sql) — this class does not duplicate
/// role checks.
abstract interface class SchedulesRepository {
  Future<List<Shift>> fetchShiftsForVenue(String venueId);

  Future<void> createShift({
    required String venueId,
    String? staffId,
    String? roleLabel,
    required DateTime startTime,
    required DateTime endTime,
  });

  Future<void> deleteShift(String shiftId);

  Future<List<ShiftSwap>> fetchSwapsForVenue(String venueId);

  /// Caller must currently be assigned to [shiftId] — enforced by RLS
  /// (shift_swaps_insert_own_shift), not duplicated here.
  Future<void> requestSwap({required String shiftId, String? offeredTo});

  /// Accepting reassigns the shift automatically via a database trigger — this call does not
  /// separately update the shift.
  Future<void> acceptSwap({required String swapId, required String accepterUserId});

  Future<void> cancelSwap(String swapId);

  Future<void> declineSwap(String swapId);
}

class SupabaseSchedulesRepository implements SchedulesRepository {
  const SupabaseSchedulesRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Shift>> fetchShiftsForVenue(String venueId) async {
    final rows = await _client
        .from('shifts')
        .select()
        .eq('venue_id', venueId)
        .order('start_time');

    return rows.map(Shift.fromJson).toList(growable: false);
  }

  @override
  Future<void> createShift({
    required String venueId,
    String? staffId,
    String? roleLabel,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    await _client.from('shifts').insert({
      'venue_id': venueId,
      if (staffId != null) 'staff_id': staffId,
      if (roleLabel != null) 'role_label': roleLabel,
      'start_time': startTime.toUtc().toIso8601String(),
      'end_time': endTime.toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> deleteShift(String shiftId) async {
    await _client.from('shifts').delete().eq('id', shiftId);
  }

  @override
  Future<List<ShiftSwap>> fetchSwapsForVenue(String venueId) async {
    final rows = await _client
        .from('shift_swaps')
        .select()
        .eq('venue_id', venueId)
        .order('created_at', ascending: false);

    return rows.map(ShiftSwap.fromJson).toList(growable: false);
  }

  @override
  Future<void> requestSwap({required String shiftId, String? offeredTo}) async {
    await _client.from('shift_swaps').insert({
      'shift_id': shiftId,
      if (offeredTo != null) 'offered_to': offeredTo,
    });
  }

  @override
  Future<void> acceptSwap({required String swapId, required String accepterUserId}) async {
    await _client
        .from('shift_swaps')
        .update({'status': 'accepted', 'accepted_by': accepterUserId})
        .eq('id', swapId);
  }

  @override
  Future<void> cancelSwap(String swapId) async {
    await _client.from('shift_swaps').update({'status': 'cancelled'}).eq('id', swapId);
  }

  @override
  Future<void> declineSwap(String swapId) async {
    await _client.from('shift_swaps').update({'status': 'declined'}).eq('id', swapId);
  }
}
