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
    final rows = await _client
        .from('memberships')
        .select('user_id, role, profiles(display_name)')
        .eq('venue_id', venueId);

    return rows.map(RosterMember.fromJson).toList(growable: false);
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
  Future<void> createInvite({
    required String venueId,
    required String email,
    required WorkforceRole role,
  }) async {
    await _client.from('invites').insert({
      'venue_id': venueId,
      'email': email,
      'role': role.toDb(),
    });
  }

  @override
  Future<void> revokeInvite(String inviteId) async {
    await _client
        .from('invites')
        .update({'status': 'revoked'}).eq('id', inviteId);
  }
}
