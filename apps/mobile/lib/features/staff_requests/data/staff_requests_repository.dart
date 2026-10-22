import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/unapplied_update.dart';

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

  /// Approve or deny (`review_staff_request`). Approving a pick-up that would double-book the
  /// requester is refused (code 23P01) unless [allowOverlap].
  Future<void> reviewRequest({
    required String requestId,
    required StaffRequestStatus status,
    String? responseNotes,
    bool allowOverlap = false,
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
    final row = await _client
        .from('staff_requests')
        .update({'status': 'cancelled'})
        .eq('id', requestId)
        .select('id')
        .maybeSingle();
    if (row == null) {
      await throwForUnappliedUpdate(
        rowExists: () => rowExistsById(_client, 'staff_requests', requestId),
        denialMessage: 'Request cancellation was not applied',
      );
    }
  }

  @override
  Future<void> reviewRequest({
    required String requestId,
    required StaffRequestStatus status,
    String? responseNotes,
    bool allowOverlap = false,
  }) async {
    await _client.rpc(
      'review_staff_request',
      params: {
        'p_request_id': requestId,
        'p_status': status.toDb(),
        'p_response_notes':
            (responseNotes?.isEmpty ?? true) ? null : responseNotes,
        'p_allow_overlap': allowOverlap,
      },
    );
  }
}
