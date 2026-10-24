import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/timesheet.dart';

/// The manager-facing side of the time clock. Authorization is server-side: the clock board
/// is for supervisors and up, the timesheet and corrections for managers of the venue (see
/// supabase/migrations/20261022100000_venue_location_and_hours.sql).
abstract interface class TimesheetRepository {
  Future<List<ClockBoardRow>> fetchClockBoard(String venueId);

  Future<List<TimesheetEntry>> fetchTimesheet({
    required String venueId,
    required DateTime from,
    required DateTime to,
  });

  /// Closes a missed clock-out (or moves a recorded one) through `public.correct_time_entry`,
  /// which keeps who made the change, the original value and [reason] in the audit log.
  Future<void> correctClockOut({
    required String timeEntryId,
    required DateTime clockOutAt,
    required String reason,
  });
}

class SupabaseTimesheetRepository implements TimesheetRepository {
  const SupabaseTimesheetRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<ClockBoardRow>> fetchClockBoard(String venueId) async {
    final rows = await _call(
      'venue_clock_board',
      {'p_venue_id': venueId},
    );
    return rows.map(ClockBoardRow.fromJson).toList(growable: false);
  }

  @override
  Future<List<TimesheetEntry>> fetchTimesheet({
    required String venueId,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _call('venue_timesheet', {
      'p_venue_id': venueId,
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    });
    return rows.map(TimesheetEntry.fromJson).toList(growable: false);
  }

  @override
  Future<void> correctClockOut({
    required String timeEntryId,
    required DateTime clockOutAt,
    required String reason,
  }) async {
    await _call('correct_time_entry', {
      'p_entry_id': timeEntryId,
      'p_clock_out_at': clockOutAt.toUtc().toIso8601String(),
      'p_breaks': null,
      'p_reason': reason,
    });
  }

  Future<List<Map<String, dynamic>>> _call(
    String fn,
    Map<String, dynamic> params,
  ) async {
    try {
      final result = await _client.rpc(fn, params: params);
      if (result is List) {
        return result
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList(growable: false);
      }
      return const [];
    } on PostgrestException catch (e) {
      throw _map(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  AppError _map(PostgrestException e) {
    if (e.code == '42501') {
      if (e.message.contains('own time entries')) {
        return const PermissionDeniedError(
          'Managers cannot change their own punches. Ask another manager.',
        );
      }
      return const PermissionDeniedError(
        'Only managers of this venue can see or change hours.',
      );
    }
    if (e.code == '22023') return UnknownError(_sentence(e.message));
    if (e.code == 'P0002') {
      return const NotFoundError('That punch no longer exists.');
    }
    return UnknownError(e.message);
  }

  static String _sentence(String message) => message.isEmpty
      ? 'That change is not valid.'
      : '${message[0].toUpperCase()}${message.substring(1)}.';
}
