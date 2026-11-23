import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/workforce_models.dart';

/// As with the other Phase 2/3 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002100000_workforce_invites.sql) — this class does not duplicate
/// role checks.
abstract interface class WorkforceRepository {
  Future<List<RosterMember>> fetchRosterForVenue(String venueId);

  Future<List<Invite>> fetchInvitesForVenue(String venueId);

  Future<void> createInvite({
    required String venueId,
    required String email,
    required WorkforceRole role,
  });

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

    // Skip unknown role/status rows instead of failing the entire list (M17).
    return rows
        .map(
          (row) => Invite.tryFromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .whereType<Invite>()
        .toList(growable: false);
  }

  @override
  Future<void> createInvite({
    required String venueId,
    required String email,
    required WorkforceRole role,
  }) async {
    final response = await _client.functions.invoke(
      'invite-member',
      body: {
        'venue_id': venueId,
        'email': email,
        'role': role.toDb(),
      },
    );
    if (response.status != 200) {
      throw StateError('Invitation email was not sent. Please retry.');
    }
  }

  @override
  Future<void> revokeInvite(String inviteId) async {
    // Revocation is restricted to public.revoke_invite so clients cannot mark
    // invites accepted without creating a membership (see accept_invite).
    // The RPC raises on not-found / forbidden / not-pending (no silent RLS no-op).
    await _client.rpc('revoke_invite', params: {'p_invite_id': inviteId});
  }
}
