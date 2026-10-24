import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/unapplied_update.dart';

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

  /// Fires whenever a shift or swap at [venueId] changes (realtime, RLS-filtered), so open
  /// schedule screens can reload instead of showing — and later saving over — stale data.
  Stream<void> watchScheduleChanges(String venueId);

  /// Moves/reassigns/edits a shift. [staffId] null with [clearStaff] makes it an open shift.
  /// Pass only the fields that changed. With [expectedVersion] the write applies only if the
  /// shift is still at that version, and throws [StaleShiftException] if someone changed it.
  Future<void> updateShift({
    required String shiftId,
    int? expectedVersion,
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

  /// Offers to take a swap as the signed-in user (`claim_shift_swap`). Staff then wait for a
  /// manager; a manager taking it themselves is applied at once. Returns the new status.
  /// Refused with code 23P01 when it would double-book, unless [allowOverlap].
  Future<ShiftSwapStatus> claimSwap({
    required String swapId,
    bool allowOverlap = false,
  });

  /// Manager approval on behalf of whoever is taking the shift (`approve_shift_swap`). The
  /// database trigger then reassigns it; the manager is never put on the shift.
  Future<void> approveSwap({
    required String swapId,
    bool allowOverlap = false,
  });

  /// The taker withdraws a claimed swap that is awaiting manager approval
  /// (`unclaim_shift_swap`); it goes back to open for anyone eligible.
  Future<void> unclaimShiftSwap(String swapId);

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
  Stream<void> watchScheduleChanges(String venueId) {
    late final RealtimeChannel channel;
    late final StreamController<void> controller;
    void emit(PostgresChangePayload _) {
      if (!controller.isClosed) controller.add(null);
    }

    controller = StreamController<void>(
      onListen: () {
        final filter = PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'venue_id',
          value: venueId,
        );
        channel = _client
            .channel('schedule:$venueId')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'shifts',
              filter: filter,
              callback: emit,
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'shift_swaps',
              filter: filter,
              callback: emit,
            )
            .subscribe();
      },
      onCancel: () {
        unawaited(_client.removeChannel(channel));
      },
    );
    return controller.stream;
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
    int? expectedVersion,
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
      // Empty string clears the role.
      if (roleLabel != null) 'role_label': roleLabel.isEmpty ? null : roleLabel,
      // Empty string clears the section.
      if (section != null) 'section': section.isEmpty ? null : section,
      if (startTime != null) 'start_time': startTime.toUtc().toIso8601String(),
      if (endTime != null) 'end_time': endTime.toUtc().toIso8601String(),
      if (status != null) 'status': status.toDb(),
    };
    if (patch.isEmpty) return;
    var query = _client.from('shifts').update(patch).eq('id', shiftId);
    if (expectedVersion != null) query = query.eq('version', expectedVersion);
    final row = await query.select('id').maybeSingle();
    if (row == null) {
      if (expectedVersion != null) {
        final current = await _client
            .from('shifts')
            .select('version')
            .eq('id', shiftId)
            .maybeSingle();
        final version = (current?['version'] as num?)?.toInt();
        if (version != null && version != expectedVersion) {
          throw const StaleShiftException();
        }
      }
      await throwForUnappliedUpdate(
        rowExists: () => rowExistsById(_client, 'shifts', shiftId),
        denialMessage: 'Shift update was not applied',
      );
    }
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
  Future<ShiftSwapStatus> claimSwap({
    required String swapId,
    bool allowOverlap = false,
  }) async {
    final status = await _client.rpc(
      'claim_shift_swap',
      params: {'p_swap_id': swapId, 'p_allow_overlap': allowOverlap},
    );
    return ShiftSwapStatus.fromDb(status as String);
  }

  @override
  Future<void> approveSwap({
    required String swapId,
    bool allowOverlap = false,
  }) async {
    await _client.rpc(
      'approve_shift_swap',
      params: {'p_swap_id': swapId, 'p_allow_overlap': allowOverlap},
    );
  }

  @override
  Future<void> unclaimShiftSwap(String swapId) async {
    await _client.rpc('unclaim_shift_swap', params: {'p_swap_id': swapId});
  }

  @override
  Future<void> cancelSwap(String swapId) async {
    final row = await _client
        .from('shift_swaps')
        .update({'status': 'cancelled'})
        .eq('id', swapId)
        .select('id')
        .maybeSingle();
    if (row == null) {
      await throwForUnappliedUpdate(
        rowExists: () => rowExistsById(_client, 'shift_swaps', swapId),
        denialMessage: 'Swap cancellation was not applied',
      );
    }
  }

  @override
  Future<void> declineSwap(String swapId) async {
    final row = await _client
        .from('shift_swaps')
        .update({'status': 'declined'})
        .eq('id', swapId)
        .select('id')
        .maybeSingle();
    if (row == null) {
      await throwForUnappliedUpdate(
        rowExists: () => rowExistsById(_client, 'shift_swaps', swapId),
        denialMessage: 'Swap decline was not applied',
      );
    }
  }
}
