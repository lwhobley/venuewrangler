import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/staff_request.dart';

abstract interface class StaffRequestsRepository {
  Future<List<StaffRequest>> fetchRequestsForVenue(String venueId);

  Future<void> createRequest({
    required String venueId,
    required StaffRequestKind kind,
    required String title,
    String details = '',
    String? requestedForDate,
    String? requestedRangeStart,
    String? requestedRangeEnd,
    String? requestedShiftId,
  });

  Future<void> cancelRequest(String requestId);

  Future<void> reviewRequest({
    required String requestId,
    required StaffRequestStatus status,
    String? responseNotes,
  });
}

class SupabaseStaffRequestsRepository implements StaffRequestsRepository {
  const SupabaseStaffRequestsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<StaffRequest>> fetchRequestsForVenue(String venueId) async {
    final rows = await _client
        .from('staff_requests')
        .select()
        .eq('venue_id', venueId)
        .order('created_at', ascending: false);

    return rows.map(StaffRequest.fromJson).toList(growable: false);
  }

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
    await _client.from('staff_requests').insert({
      'venue_id': venueId,
      'kind': kind.toDb(),
      'title': title,
      'details': details,
      if (requestedForDate != null) 'requested_for_date': requestedForDate,
      if (requestedRangeStart != null)
        'requested_range_start': requestedRangeStart,
      if (requestedRangeEnd != null) 'requested_range_end': requestedRangeEnd,
      if (requestedShiftId != null) 'requested_shift_id': requestedShiftId,
    });
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    await _client
        .from('staff_requests')
        .update({'status': 'cancelled'}).eq('id', requestId);
  }

  @override
  Future<void> reviewRequest({
    required String requestId,
    required StaffRequestStatus status,
    String? responseNotes,
  }) async {
    await _client.from('staff_requests').update({
      'status': status.toDb(),
      if (responseNotes != null && responseNotes.isNotEmpty)
        'response_notes': responseNotes,
    }).eq('id', requestId);
  }
}
