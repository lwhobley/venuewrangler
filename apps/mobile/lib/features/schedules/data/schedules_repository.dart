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
}
