import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/transport_failure.dart';
import '../domain/workforce_models.dart';

/// A failed invite action with a message fit to show.
class InviteActionException implements Exception {
  const InviteActionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// As with the other Phase 2/3 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002100000_workforce_invites.sql) — this class does not duplicate
/// role checks. Invites are written through `public.create_invite`/`public.resend_invite`
/// (20261022110000_invite_onboarding.sql) and emailed by the `invite-send-email` function.
abstract interface class WorkforceRepository {
  Future<List<RosterMember>> fetchRosterForVenue(String venueId);

  Future<List<Invite>> fetchInvitesForVenue(String venueId);

  /// Creates an invite, replacing an expired or live one for the same email. Throws
  /// [InviteActionException].
  Future<Invite> createInvite({
    required String venueId,
    required String email,
    required WorkforceRole role,
    String? fullName,
  });

  /// Returns the invite to email again: the same one while it is live, a fresh copy once it
  /// has expired. Throws [InviteActionException].
  Future<Invite> resendInvite(String inviteId);

  /// Emails [inviteId] to the invitee. Throws [InviteActionException].
  Future<void> sendInviteEmail(String inviteId);

  Future<void> revokeInvite(String inviteId);
}

class SupabaseWorkforceRepository implements WorkforceRepository {
  const SupabaseWorkforceRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<RosterMember>> fetchRosterForVenue(String venueId) async {
    // An RPC rather than a table read: venue managers can't read other members' membership
    // rows, and memberships has no relationship to profiles to embed (public.venue_roster).
    final rows = await _client.rpc(
      'venue_roster',
      params: {'p_venue_id': venueId},
    ) as List<dynamic>;

    return rows
        .cast<Map<String, dynamic>>()
        .map(RosterMember.fromJson)
        .toList(growable: false);
  }

  @override
  Future<List<Invite>> fetchInvitesForVenue(String venueId) async {
    final rows = await _client
        .from('invites')
        .select()
        .eq('venue_id', venueId)
        .order('created_at', ascending: false);

    return rows.map(Invite.fromJson).toList(growable: false);
  }

  @override
  Future<Invite> createInvite({
    required String venueId,
    required String email,
    required WorkforceRole role,
    String? fullName,
  }) async {
    try {
      final row = await _client.rpc(
        'create_invite',
        params: {
          'p_venue_id': venueId,
          'p_email': email,
          'p_role': role.toDb(),
          'p_full_name': fullName,
        },
      );
      return Invite.fromJson(Map<String, dynamic>.from(row as Map));
    } catch (error) {
      throw inviteActionExceptionFrom(error);
    }
  }

  @override
  Future<Invite> resendInvite(String inviteId) async {
    try {
      final row =
          await _client.rpc('resend_invite', params: {'p_invite_id': inviteId});
      return Invite.fromJson(Map<String, dynamic>.from(row as Map));
    } catch (error) {
      throw inviteActionExceptionFrom(error);
    }
  }

  @override
  Future<void> sendInviteEmail(String inviteId) async {
    try {
      await _client.functions.invoke(
        'invite-send-email',
        body: {'invite_id': inviteId},
      );
    } catch (error) {
      throw inviteActionExceptionFrom(error);
    }
  }

  @override
  Future<void> revokeInvite(String inviteId) async {
    await _client
        .from('invites')
        .update({'status': 'revoked'}).eq('id', inviteId);
  }
}

InviteActionException inviteActionExceptionFrom(Object error) {
  if (error is InviteActionException) return error;
  if (error is PostgrestException) {
    final text = '${error.message} ${error.details} ${error.hint}';
    if (text.contains('already_member')) {
      return const InviteActionException(
        'That person is already on this team.',
      );
    }
    if (text.contains('forbidden_role')) {
      return const InviteActionException(
        'Only an owner or admin can invite or re-invite a manager.',
      );
    }
    if (text.contains('invalid_email')) {
      return const InviteActionException('Enter a valid email address.');
    }
    if (text.contains('invalid_name')) {
      return const InviteActionException('Use 120 characters or fewer.');
    }
    if (text.contains('invite_not_pending') || error.code == 'P0002') {
      return const InviteActionException(
        'This invite was already accepted or withdrawn. Send a new one.',
      );
    }
    if (error.code == '42501') {
      return const InviteActionException(
        "You don't have permission to invite staff here.",
      );
    }
  }
  if (error is FunctionException) {
    final details = error.details;
    final code = details is Map ? details['error'] as String? : null;
    return InviteActionException(
      switch (code) {
        'rate_limited' =>
          'Too many invitation emails today. Try again tomorrow.',
        'email_not_configured' =>
          'Invitation emails are not set up yet. Ask the '
              'person to sign up with "Join your team" using this email.',
        'invite_not_pending' => 'This invite has expired or was withdrawn. '
            'Send a new one.',
        'invite_not_found' => "You don't have permission to send this invite.",
        'invalid_or_expired_session' => 'Your session has expired. Sign in '
            'again.',
        _ => 'The invitation email could not be sent. Try Resend.',
      },
    );
  }
  if (isTransportFailure(error)) {
    return const InviteActionException(
      'Could not reach the server. Check your connection.',
    );
  }
  return const InviteActionException('Something went wrong. Please try again.');
}
