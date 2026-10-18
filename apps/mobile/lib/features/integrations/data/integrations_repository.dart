import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/payroll_connection.dart';

/// Reads the non-secret columns of `payroll_connections` directly (RLS + a column-level grant
/// hide the encrypted token columns entirely from any client — see
/// supabase/migrations/20261002140000_payroll_connections_schema.sql) and calls each
/// `{provider}-oauth` Edge Function's `/connect`/`/disconnect` routes for the OAuth lifecycle.
abstract interface class IntegrationsRepository {
  Future<List<PayrollConnection>> fetchConnectionsForVenue(String venueId);

  /// Returns a hosted provider authorize URL to open in an external browser.
  Future<String> createConnectUrl(PayrollProvider provider, String venueId);

  Future<void> disconnect(PayrollProvider provider, String venueId);

  /// Finishes a connection after the provider consent screen. The OAuth callback only parks the
  /// tokens behind a one-time [nonce] that is delivered to the browser that completed consent;
  /// redeeming it here with the signed-in session is what binds the connection to this user, so a
  /// consent link forwarded to someone else can never be completed by the person who minted it.
  Future<void> completeConnection(PayrollProvider provider, String nonce);
}

class SupabaseIntegrationsRepository implements IntegrationsRepository {
  const SupabaseIntegrationsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<PayrollConnection>> fetchConnectionsForVenue(
    String venueId,
  ) async {
    final rows = await _client
        .from('payroll_connections')
        .select(
          'venue_id, provider, status, external_account_id, token_expires_at, last_error',
        )
        .eq('venue_id', venueId);

    return rows.map(PayrollConnection.fromJson).toList(growable: false);
  }

  @override
  Future<String> createConnectUrl(
    PayrollProvider provider,
    String venueId,
  ) async {
    try {
      final response = await _client.functions.invoke(
        '${provider.functionSlug}/connect',
        body: {'venue_id': venueId},
      );
      final url = (response.data as Map?)?['url'] as String?;
      if (url == null) {
        throw const UnknownError(
          'Could not start the connection. Please try again.',
        );
      }
      return url;
    } on FunctionException catch (error) {
      throw _mapFunctionException(error);
    }
  }

  @override
  Future<void> disconnect(PayrollProvider provider, String venueId) async {
    try {
      await _client.functions.invoke(
        '${provider.functionSlug}/disconnect',
        body: {'venue_id': venueId},
      );
    } on FunctionException catch (error) {
      throw _mapFunctionException(error);
    }
  }

  @override
  Future<void> completeConnection(
    PayrollProvider provider,
    String nonce,
  ) async {
    try {
      await _client.functions.invoke(
        '${provider.functionSlug}/complete',
        body: {'nonce': nonce},
      );
    } on FunctionException catch (error) {
      if (error.status == 404) {
        throw const NotFoundError(
          'This connection link is not valid for your account. Start the connection again from Integrations.',
        );
      }
      if (error.status == 410) {
        throw const NotFoundError(
          'This connection link has expired or was already used. Start the connection again.',
        );
      }
      throw _mapFunctionException(error);
    }
  }

  AppError _mapFunctionException(FunctionException error) {
    final details = error.details;
    final code = details is Map ? details['error'] as String? : null;

    return switch (code) {
      'not_a_venue_manager' => const PermissionDeniedError(
          'Only a venue manager or organization admin can manage integrations.',
        ),
      'invalid_or_expired_session' =>
        const AuthError('Your session has expired. Please sign in again.'),
      _ => error.status >= 500
          ? const UnknownError('This integration is temporarily unavailable.')
          : const UnknownError('Something went wrong. Please try again.'),
    };
  }
}
