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
    String? section,
    required DateTime startTime,
    required DateTime endTime,
  });

  /// Moves/reassigns/edits a shift. [staffId] null with [clearStaff] makes it an open shift.
  Future<void> updateShift({
    required String shiftId,
    String? staffId,
    bool clearStaff = false,
    String? roleLabel,
    String? section,
    DateTime? startTime,
    DateTime? endTime,
    ShiftStatus? status,
  });

  /// Deletes a local draft or retains an exported shift as cancelled for POS publication.
  Future<void> deleteShift(String shiftId);

  Future<List<ShiftSwap>> fetchSwapsForVenue(String venueId);

  /// Caller must currently be assigned to [shiftId] — enforced by RLS
  /// (shift_swaps_insert_own_shift), not duplicated here.
  Future<void> requestSwap({required String shiftId, String? offeredTo});

  /// Accepting reassigns the shift automatically via a database trigger — this call does not
  /// separately update the shift.
  Future<void> acceptSwap({
    required String swapId,
    required String accepterUserId,
  });

  Future<void> cancelSwap(String swapId);

  Future<void> declineSwap(String swapId);
}

class SupabaseSchedulesRepository implements SchedulesRepository {
  const SupabaseSchedulesRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Shift>> fetchShiftsForVenue(String venueId) async {
    // The board allows dates one year either side of today. Bound that window
    // in SQL and page it, so years of old shifts cannot consume the first
    // 1,000 PostgREST rows and hide today's schedule.
    final now = DateTime.now().toUtc();
    final from = now.subtract(const Duration(days: 367)).toIso8601String();
    final to = now.add(const Duration(days: 367)).toIso8601String();
    const pageSize = 500;
    final shifts = <Shift>[];
    for (var offset = 0;; offset += pageSize) {
      final rows = await _client
          .from('shifts')
          .select()
          .eq('venue_id', venueId)
          .gte('start_time', from)
          .lte('start_time', to)
          .order('start_time')
          .order('id')
          .range(offset, offset + pageSize - 1);
      shifts.addAll(rows.map(Shift.fromJson));
      if (rows.length < pageSize) break;
    }
    return shifts;
  }

  @override
  Future<void> createShift({
    required String venueId,
    String? staffId,
    String? roleLabel,
    String? section,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    await _client.from('shifts').insert({
      'venue_id': venueId,
      if (staffId != null) 'staff_id': staffId,
      if (roleLabel != null) 'role_label': roleLabel,
      if (section != null && section.isNotEmpty) 'section': section,
      'start_time': startTime.toUtc().toIso8601String(),
      'end_time': endTime.toUtc().toIso8601String(),
    });
  }

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
    final patch = <String, dynamic>{
      if (clearStaff)
        'staff_id': null
      else if (staffId != null)
        'staff_id': staffId,
      if (roleLabel != null) 'role_label': roleLabel,
      // Empty string clears the section.
      if (section != null) 'section': section.isEmpty ? null : section,
      if (startTime != null) 'start_time': startTime.toUtc().toIso8601String(),
      if (endTime != null) 'end_time': endTime.toUtc().toIso8601String(),
      if (status != null) 'status': status.toDb(),
    };
    if (patch.isEmpty) return;
    await _client.from('shifts').update(patch).eq('id', shiftId);
  }

  @override
  Future<void> deleteShift(String shiftId) async {
    await _client.rpc(
      'remove_or_cancel_shift',
      params: {'p_shift_id': shiftId},
    );
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
  Future<void> acceptSwap({
    required String swapId,
    required String accepterUserId,
  }) async {
    await _client.from('shift_swaps').update(
      {'status': 'accepted', 'accepted_by': accepterUserId},
    ).eq('id', swapId);
  }

  @override
  Future<void> cancelSwap(String swapId) async {
    await _client
        .from('shift_swaps')
        .update({'status': 'cancelled'}).eq('id', swapId);
  }

  @override
  Future<void> declineSwap(String swapId) async {
    await _client
        .from('shift_swaps')
        .update({'status': 'declined'}).eq('id', swapId);
  }
}
