import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/errors/server_denials.dart';
import '../domain/brighthr_models.dart';

/// Reads imported BrightHR data directly (manager-tier RLS; the encrypted client secret is never
/// selectable) and calls the `brighthr` Edge Function for everything that needs the secret or
/// writes: connect, sync, link, disconnect.
abstract interface class BrightHrRepository {
  Future<BrightHrConnection?> fetchConnection(String venueId);

  Future<List<BrightHrEmployee>> fetchEmployees(String connectionId);

  /// Absences that have not ended yet, soonest first.
  Future<List<BrightHrAbsence>> fetchUpcomingAbsences(String connectionId);

  /// Clock-ins from the last 14 days, newest first.
  Future<List<BrightHrClocking>> fetchRecentClockings(String connectionId);

  Future<void> connect({
    required String venueId,
    required String clientId,
    required String clientSecret,
  });

  Future<void> syncNow(String venueId);

  /// Links [externalEmployeeId] to [staffId], or unlinks it when [staffId] is null.
  Future<void> link({
    required String venueId,
    required String externalEmployeeId,
    required String? staffId,
  });

  Future<void> disconnect(String venueId);
}

class SupabaseBrightHrRepository implements BrightHrRepository {
  const SupabaseBrightHrRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<BrightHrConnection?> fetchConnection(String venueId) async {
    final row = await _client
        .from('brighthr_connections')
        .select(
          'id, venue_id, status, client_id, last_sync_at, last_sync_status, last_error',
        )
        .eq('venue_id', venueId)
        .maybeSingle();
    return row == null ? null : BrightHrConnection.fromJson(row);
  }

  @override
  Future<List<BrightHrEmployee>> fetchEmployees(String connectionId) async {
    final results = await Future.wait([
      _client
          .from('brighthr_employees')
          .select(
            'external_employee_id, given_name, family_name, email, job_title, employment_end',
          )
          .eq('connection_id', connectionId)
          .order('family_name')
          .order('given_name'),
      _client
          .from('brighthr_employee_mappings')
          .select(
            'external_employee_id, staff_id, external_reference_synced_at',
          )
          .eq('connection_id', connectionId),
    ]);
    final mappings = {
      for (final m in results[1]) m['external_employee_id'] as String: m,
    };
    return results[0]
        .map(
          (row) => BrightHrEmployee.fromJson(
            row,
            mapping: mappings[row['external_employee_id']],
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<BrightHrAbsence>> fetchUpcomingAbsences(
    String connectionId,
  ) async {
    final today = DateTime.now();
    final todayIso =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final rows = await _client
        .from('brighthr_absences')
        .select(
          'external_absence_id, external_employee_id, absence_type, display_name, start_date, start_part, end_date, end_part',
        )
        .eq('connection_id', connectionId)
        .gte('end_date', todayIso)
        .order('start_date')
        .limit(500);
    return rows.map(BrightHrAbsence.fromJson).toList(growable: false);
  }

  @override
  Future<List<BrightHrClocking>> fetchRecentClockings(
    String connectionId,
  ) async {
    final since = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 14))
        .toIso8601String();
    final rows = await _client
        .from('brighthr_clockings')
        .select(
          'external_clocking_id, external_employee_id, clock_in_at, clock_out_at, break_periods',
        )
        .eq('connection_id', connectionId)
        .gte('clock_in_at', since)
        .order('clock_in_at', ascending: false)
        .limit(500);
    return rows.map(BrightHrClocking.fromJson).toList(growable: false);
  }

  @override
  Future<void> connect({
    required String venueId,
    required String clientId,
    required String clientSecret,
  }) =>
      _invoke('connect', {
        'venue_id': venueId,
        'client_id': clientId,
        'client_secret': clientSecret,
      });

  @override
  Future<void> syncNow(String venueId) =>
      _invoke('sync', {'venue_id': venueId});

  @override
  Future<void> link({
    required String venueId,
    required String externalEmployeeId,
    required String? staffId,
  }) =>
      _invoke('link', {
        'venue_id': venueId,
        'external_employee_id': externalEmployeeId,
        'staff_id': staffId,
      });

  @override
  Future<void> disconnect(String venueId) =>
      _invoke('disconnect', {'venue_id': venueId});

  Future<void> _invoke(String route, Map<String, dynamic> body) async {
    try {
      await _client.functions.invoke('brighthr/$route', body: body);
    } on FunctionException catch (error) {
      throw mapBrightHrFunctionError(error.status, error.details);
    }
  }
}

/// Maps a `brighthr` Edge Function error body to a user-facing [AppError].
AppError mapBrightHrFunctionError(int status, Object? details) {
  final code = details is Map ? details['error'] as String? : null;
  return switch (code) {
    'brighthr_invalid_credentials' => const UnknownError(
        'BrightHR did not accept that Client ID and Secret. Check them in BrightHR under API Management.',
      ),
    'brighthr_forbidden' => const PermissionDeniedError(
        'That BrightHR API application does not have access to employee data.',
      ),
    'brighthr_unavailable' =>
      const NetworkError('Could not reach BrightHR. Try again shortly.'),
    'invalid_credentials_format' =>
      const UnknownError('Enter both the Client ID and the Client Secret.'),
    'not_a_venue_manager' => const PermissionDeniedError(
        'Only a venue manager or organization admin can manage integrations.',
      ),
    // 403: connecting or disconnecting BrightHR needs an authenticator-verified session.
    mfaRequiredCode => const MfaRequiredError(),
    mfaCheckUnavailableCode => const NetworkError(mfaCheckUnavailableMessage),
    'not_a_venue_member' =>
      const UnknownError('That person is not a member of this venue.'),
    'unknown_brighthr_employee' => const NotFoundError(
        'That BrightHR employee was not found. Pull to refresh and try again.',
      ),
    'not_connected' => const NotFoundError('BrightHR is not connected.'),
    'sync_in_progress' =>
      const UnknownError('A sync is already running. Pull to refresh shortly.'),
    'rate_limited' => const UnknownError(
        'Too many attempts. Wait a few minutes and try again.',
      ),
    'invalid_or_expired_session' =>
      const AuthError('Your session has expired. Please sign in again.'),
    _ => status >= 500
        ? const UnknownError('BrightHR is temporarily unavailable.')
        : const UnknownError('Something went wrong. Please try again.'),
  };
}
