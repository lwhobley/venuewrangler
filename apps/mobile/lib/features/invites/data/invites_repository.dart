import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/transport_failure.dart';
import '../domain/pending_invite.dart';

/// A failed invite call with a message fit to show.
class InviteException implements Exception {
  const InviteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Invites are no longer redeemed automatically at sign-up: the person sees what they were
/// invited to and accepts explicitly. The server checks the invite email equals the signed-in
/// user's verified email.
abstract interface class InvitesRepository {
  /// `public.my_pending_invites()`.
  Future<List<PendingInvite>> fetchPending();

  /// `public.accept_invite(p_invite_id)`: creates the membership.
  Future<void> accept(String inviteId);
}

class SupabaseInvitesRepository implements InvitesRepository {
  const SupabaseInvitesRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<PendingInvite>> fetchPending() async {
    final rows = await _client.rpc('my_pending_invites') as List<dynamic>;
    return [
      for (final row in rows)
        PendingInvite.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<void> accept(String inviteId) async {
    try {
      await _client.rpc('accept_invite', params: {'p_invite_id': inviteId});
    } catch (error) {
      throw inviteExceptionFrom(error);
    }
  }
}

InviteException inviteExceptionFrom(Object error) {
  if (error is PostgrestException) {
    final text = '${error.message} ${error.details} ${error.hint}';
    if (text.contains('email_not_verified')) {
      return const InviteException(
        'Confirm your email address first (check your inbox), then accept '
        'the invite.',
      );
    }
    if (text.contains('invite_not_pending')) {
      return const InviteException(
        'This invite was already used or withdrawn.',
      );
    }
    if (error.code == '42501') {
      return const InviteException(
        'This invite was sent to a different email address, or your email is '
        'not verified yet.',
      );
    }
    if (error.code == 'P0002') {
      return const InviteException(
        'This invite is no longer available. Ask the venue to send a new one.',
      );
    }
  }
  if (isTransportFailure(error)) {
    return const InviteException(
      'Could not reach the server. Check your connection.',
    );
  }
  return const InviteException(
    'Could not accept the invite. Please try again.',
  );
}
